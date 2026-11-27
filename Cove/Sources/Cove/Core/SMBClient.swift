import Foundation
import Security
import AMSMB2
import CryptoKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - NAS File Entry & Client Registry

struct NASFileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int
    let modifiedAt: Date?
    let fileType: FileType
    let displaySize: String

    init(name: String, path: String, isDirectory: Bool, size: Int, modifiedAt: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileType = isDirectory ? .unknown : FileType.detect(fromPath: path)
        self.displaySize = isDirectory ? "" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct NASConfigSnapshot: Sendable {
    let id: UUID
    let host: String
    let port: Int
    let username: String
    let shareName: String

    init(config: NASConfig) {
        self.id = config.id
        self.host = config.host
        self.port = config.port
        self.username = config.username
        self.shareName = config.shareName
    }
}

actor SMBClientRegistry {
    static let shared = SMBClientRegistry()
    private var clients: [String: SMBClient] = [:]

    func register(_ client: SMBClient) { clients[client.cacheIdentity] = client }
    func unregister(_ client: SMBClient) { clients.removeValue(forKey: client.cacheIdentity) }
    func client(for identity: String) -> SMBClient? { clients[identity] }
}

// MARK: - SMB Client

protocol SMBRangeSource: Sendable {
    func fileSize(at path: String) async throws -> Int64
    func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data
}

actor SMBClient: SMBRangeSource {
    private var client: SMB2Manager?
    private var dirCache: [String: (entries: [NASFileEntry], date: Date)] = [:]
    private var generation = UUID()
    private let config: NASConfigSnapshot
    nonisolated let cacheIdentity: String

    init(config: NASConfig) { self.init(snapshot: NASConfigSnapshot(config: config)) }

    init(snapshot: NASConfigSnapshot) {
        self.config = snapshot
        let fields = [snapshot.id.uuidString, snapshot.host, String(snapshot.port), snapshot.username, snapshot.shareName]
        self.cacheIdentity = SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func smbURL(host: String, port: Int = 445) -> URL? {
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("smb://") { cleaned = String(cleaned.dropFirst(6)) }
        var resolvedPort = port
        if cleaned.filter({ $0 == ":" }).count == 1, let colon = cleaned.lastIndex(of: ":"),
           let p = Int(cleaned[cleaned.index(after: colon)...]), (1...65535).contains(p) {
            cleaned = String(cleaned[..<colon])
            resolvedPort = p
        }
        guard !cleaned.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = "smb"; comps.host = cleaned
        if resolvedPort > 0 && resolvedPort != 445 { comps.port = resolvedPort }
        return comps.url
    }

    static func listShares(host: String, port: Int = 445, username: String, password: String) async throws -> [(name: String, comment: String)] {
        guard let url = smbURL(host: host, port: port),
              let mgr = SMB2Manager(url: url, credential: URLCredential(user: username, password: password, persistence: .forSession)) else {
            throw SMBError.invalidURL
        }
        return try await mgr.listShares()
    }

    func connect(password: String) async throws {
        let previous = client; client = nil
        generation = UUID()
        let currentGen = generation
        dirCache.removeAll()
        try? await previous?.disconnectShare()
        guard let url = Self.smbURL(host: config.host, port: config.port),
              let mgr = SMB2Manager(url: url, credential: URLCredential(user: config.username, password: password, persistence: .forSession)) else {
            throw SMBError.invalidURL
        }
        try await mgr.connectShare(name: config.shareName)
        guard currentGen == generation else { try? await mgr.disconnectShare(); throw CancellationError() }
        client = mgr
        await SMBClientRegistry.shared.register(self)
    }

    func disconnect() async {
        generation = UUID()
        let previous = client; client = nil
        dirCache.removeAll()
        await SMBClientRegistry.shared.unregister(self)
        try? await previous?.disconnectShare()
    }

    func listDirectory(path: String = "/", refresh: Bool = false) async throws -> [NASFileEntry] {
        guard let client else { throw SMBError.notConnected }
        if !refresh, let cached = dirCache[path], Date().timeIntervalSince(cached.date) < 60 { return cached.entries }
        let items = try await client.contentsOfDirectory(atPath: path).compactMap { item -> NASFileEntry? in
            guard let name = item[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            return NASFileEntry(
                name: name, path: (path as NSString).appendingPathComponent(name),
                isDirectory: isDir, size: (item[.fileSizeKey] as? Int) ?? 0,
                modifiedAt: item[.contentModificationDateKey] as? Date
            )
        }.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        dirCache[path] = (items, Date())
        return items
    }

    func fileSize(at remotePath: String) async throws -> Int64 {
        guard let client else { throw SMBError.notConnected }
        let attrs = try await client.attributesOfItem(atPath: remotePath)
        return (attrs[.fileSizeKey] as? Int64) ?? (attrs[.fileSizeKey] as? Int).map(Int64.init) ?? 0
    }

    func readRange(at remotePath: String, offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard length > 0, length <= 512 * 1024, offset <= UInt64.max - UInt64(length) else { throw SMBError.invalidRange }
        guard let client else { throw SMBError.notConnected }
        return try await client.contents(atPath: remotePath, range: offset ..< (offset + UInt64(length)))
    }

    func readFile(at remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        try await SMBFileRead.data(from: self, path: remotePath, progress: progress)
    }

    func temporaryFile(for remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let client else { throw SMBError.notConnected }
        let size = try await fileSize(at: remotePath)
        let maxBytes: Int64 = 500 * 1024 * 1024
        guard size <= maxBytes else { throw SMBError.tooLarge(maxBytes) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASOpen", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
        let control = SMBTransferControl(maxBytes: maxBytes)
        do {
            try await withTaskCancellationHandler {
                try await client.downloadItem(atPath: remotePath, to: dest) { completed, total in
                    guard control.accept(completed: completed, total: total) else { return false }
                    progress?(total > 0 ? Double(completed) / Double(total) : 0)
                    return true
                }
                try control.check()
            } onCancel: { control.cancel() }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }
}

enum SMBFileRead {
    static let chunkBytes = 512 * 1024
    static let maxMemoryBytes: Int64 = 32 * 1024 * 1024

    static func data(from source: any SMBRangeSource, path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let size = try await source.fileSize(at: path)
        guard size >= 0, size <= maxMemoryBytes else { throw SMBError.tooLarge(maxMemoryBytes) }
        var result = Data()
        while result.count < size {
            try Task.checkCancellation()
            let len = min(chunkBytes, Int(size) - result.count)
            let chunk = try await source.readRange(at: path, offset: UInt64(result.count), length: len)
            guard chunk.count <= len else { throw SMBError.invalidRange }
            result.append(chunk)
            progress?(Double(result.count) / Double(max(size, 1)))
            if chunk.count < len { break }
        }
        return result
    }
}

private final class SMBTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int64
    private var cancelled = false, exceeded = false
    init(maxBytes: Int64) { self.maxBytes = maxBytes }
    func cancel() { lock.withLock { cancelled = true } }
    func accept(completed: Int64, total: Int64) -> Bool {
        lock.withLock { exceeded = exceeded || completed > maxBytes || total > maxBytes; return !cancelled && !exceeded }
    }
    func check() throws {
        try lock.withLock { if cancelled { throw CancellationError() }; if exceeded { throw SMBError.tooLarge(maxBytes) } }
    }
}

enum SMBError: LocalizedError {
    case notConnected, invalidURL, invalidRange, tooLarge(Int64)
    var errorDescription: String? {
        switch self {
        case .notConnected: "NAS 未连接"
        case .invalidURL: "无效的 NAS 地址"
        case .invalidRange: "文件读取范围无效"
        case .tooLarge(let limit): "文件超过 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) 限制"
        }
    }
}

// MARK: - Keychain (preserves v1 namespace)

enum NASKeychain {
    private static let service = "com.easyreader.nas"

    static func save(password: String, for configID: UUID) {
        delete(for: configID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configID.uuidString,
            kSecValueData as String: Data(password.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for configID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for configID: UUID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configID.uuidString
        ] as CFDictionary)
    }
}

// MARK: - Streaming SMB Asset Loader

final class SMBStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "smb-stream"
    static func supportsVideo(path: String) -> Bool {
        ["mp4", "mov", "m4v", "ts"].contains((path as NSString).pathExtension.lowercased())
    }

    private let client: any SMBRangeSource
    private let remotePath: String
    private let queue = DispatchQueue(label: "smb-stream", qos: .userInitiated)
    private let lock = NSLock()
    private var cachedFileSize: Int64?
    private var requests: [ObjectIdentifier: (id: UUID, task: Task<Void, Never>)] = [:]
    private nonisolated(unsafe) static var associatedKey: UInt8 = 0

    private init(client: any SMBRangeSource, remotePath: String) {
        self.client = client
        self.remotePath = remotePath
    }

    static func makeAsset(client: any SMBRangeSource, remotePath: String) -> AVURLAsset {
        let loader = SMBStreamLoader(client: client, remotePath: remotePath)
        var comps = URLComponents()
        comps.scheme = scheme; comps.host = "nas"
        comps.path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        let asset = AVURLAsset(url: comps.url ?? URL(string: "\(scheme)://nas/stream")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(asset, &associatedKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func makePlayerItem(client: any SMBRangeSource, remotePath: String) -> AVPlayerItem {
        AVPlayerItem(asset: makeAsset(client: client, remotePath: remotePath))
    }

    static func cancel(in asset: AVAsset?) {
        guard let asset = asset as? AVURLAsset else { return }
        (asset.resourceLoader.delegate as? SMBStreamLoader)?.cancelAll()
        asset.cancelLoading()
    }

    private func cancelAll() {
        lock.withLock {
            requests.values.forEach { $0.task.cancel() }
            requests.removeAll()
        }
    }
    deinit { cancelAll() }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest), id = UUID()
        lock.withLock {
            requests[key]?.task.cancel()
            requests[key] = (id, Task { [weak self] in
                await self?.handle(loadingRequest)
                self?.lock.withLock { if self?.requests[key]?.id == id { self?.requests.removeValue(forKey: key) } }
            })
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { requests.removeValue(forKey: ObjectIdentifier(loadingRequest))?.task.cancel() }
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let fileSize: Int64
            if let cached = lock.withLock({ cachedFileSize }) { fileSize = cached }
            else {
                let s = try await client.fileSize(at: remotePath)
                lock.withLock { cachedFileSize = s }
                fileSize = s
            }
            guard fileSize > 0 else { request.finishLoading(with: SMBError.invalidRange); return }
            if let info = request.contentInformationRequest {
                info.contentType = UTType(filenameExtension: (remotePath as NSString).pathExtension.lowercased())?.identifier ?? "public.data"
                info.contentLength = fileSize
                info.isByteRangeAccessSupported = true
            }
            if let dataReq = request.dataRequest {
                let start = max(dataReq.currentOffset, dataReq.requestedOffset)
                guard start >= 0, dataReq.requestedLength >= 0 else { throw SMBError.invalidRange }
                let length = dataReq.requestsAllDataToEndOfResource
                    ? Int(max(0, fileSize - start))
                    : max(0, dataReq.requestedLength - Int(start - dataReq.requestedOffset))
                var read = 0
                while read < length {
                    try Task.checkCancellation()
                    if request.isCancelled { return }
                    let offset = UInt64(start) + UInt64(read)
                    guard offset < UInt64(fileSize) else { break }
                    let want = min(length - read, 512 * 1024, Int(UInt64(fileSize) - offset))
                    guard want > 0 else { break }
                    let data = try await client.readRange(at: remotePath, offset: offset, length: want)
                    guard data.count <= want else { throw SMBError.invalidRange }
                    dataReq.respond(with: data)
                    read += data.count
                    if data.count < want { break }
                }
            }
            request.finishLoading()
        } catch {
            if !Task.isCancelled, !request.isCancelled { request.finishLoading(with: error) }
        }
    }
}
