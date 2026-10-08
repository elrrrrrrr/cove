import Foundation
import Security
import AMSMB2
import CryptoKit

// MARK: - Shared NAS file entry

/// File/directory entry returned by SMBClient.
struct NASFileEntry: Identifiable, Sendable {
    let id = UUID()
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
        self.fileType = isDirectory ? .unknown : FileTypeDetector.detect(fromPath: path)
        self.displaySize = isDirectory ? "" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// Sendable snapshot — avoids passing SwiftData @Model across actor boundaries
struct NASConfigSnapshot: Sendable {
    let id: UUID
    let host      : String
    let port      : Int
    let username  : String
    let shareName : String

    init(config: NASConfig) {
        id = config.id
        host      = config.host
        port      = config.port
        username  = config.username
        shareName = config.shareName
    }
}

/// Wrapper around AMSMB2 providing async SMB2/3 file operations.
actor SMBClient: SMBRangeSource, OfflineDownloadSource {

    typealias FileEntry = NASFileEntry

    private var client: SMB2Manager?
    private let directories = NASDirectoryCache()
    private var connectionGeneration = UUID()
    private let config: NASConfigSnapshot
    nonisolated let cacheIdentity: String

    init(config: NASConfig) {
        let snapshot = NASConfigSnapshot(config: config)
        self.config = snapshot
        cacheIdentity = Self.identity(snapshot)
    }

    init(snapshot: NASConfigSnapshot) {
        self.config = snapshot
        cacheIdentity = Self.identity(snapshot)
    }

    private static func identity(_ value: NASConfigSnapshot) -> String {
        let fields = [value.id.uuidString, value.host, String(value.port), value.username, value.shareName]
        return SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Share Discovery

    /// Lists available SMB shares on the server (no prior connection needed).
    static func listShares(host: String, username: String, password: String) async throws -> [(name: String, comment: String)] {
        guard let url = URL(string: "smb://\(host)") else {
            throw SMBError.invalidURL
        }
        let credential = URLCredential(user: username, password: password, persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else {
            throw SMBError.invalidURL
        }
        return try await mgr.listShares()
    }

    // MARK: - Connection

    func connect(password: String) async throws {
        let previous = client; client = nil
        connectionGeneration = UUID()
        let generation = connectionGeneration
        await directories.clear()
        try? await previous?.disconnectShare()
        guard let url = URL(string: "smb://\(config.host)") else {
            throw SMBError.invalidURL
        }
        let credential = URLCredential(
            user: config.username,
            password: password,
            persistence: .forSession
        )
        guard let mgr = SMB2Manager(url: url, credential: credential) else {
            throw SMBError.invalidURL
        }
        try await mgr.connectShare(name: config.shareName)
        guard generation == connectionGeneration else { try? await mgr.disconnectShare(); throw CancellationError() }
        self.client = mgr
    }

    func disconnect() async {
        connectionGeneration = UUID()
        let previous = client; client = nil
        await directories.clear()
        try? await previous?.disconnectShare()
    }

    // MARK: - Directory listing

    func listDirectory(path: String = "/", refresh: Bool = false) async throws -> [FileEntry] {
        guard client != nil else { throw SMBError.notConnected }
        let generation = connectionGeneration
        let items = try await directories.load(path: path, refresh: refresh) { try await self.fetchDirectory(path: path, generation: generation) }
        guard generation == connectionGeneration else { throw CancellationError() }
        return items
    }

    private func fetchDirectory(path: String, generation: UUID) async throws -> [FileEntry] {
        guard generation == connectionGeneration, let client else { throw SMBError.notConnected }

        let contents = try await client.contentsOfDirectory(atPath: path)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        return contents.compactMap { item -> FileEntry? in
            guard let name = item[.nameKey] as? String,
                  !name.hasPrefix(".")  else { return nil }
            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size  = (item[.fileSizeKey] as? Int) ?? 0
            let mod   = item[.contentModificationDateKey] as? Date
            return FileEntry(
                name: name,
                path: (path as NSString).appendingPathComponent(name),
                isDirectory: isDir,
                size: size,
                modifiedAt: mod
            )
        }
        .sorted { a, b in
            // Directories first, then alphabetical
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Range read

    /// Reads a byte range from a remote file. Used for thumbnail extraction and streaming.
    func readRange(at remotePath: String, offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard length > 0, length <= SMBFileRead.chunkBytes, offset <= UInt64.max - UInt64(length) else {
            throw SMBError.invalidRange
        }
        guard let client else { throw SMBError.notConnected }
        let range: Range<UInt64> = offset ..< (offset + UInt64(length))
        let data = try await client.contents(atPath: remotePath, range: range)
        try Task.checkCancellation()
        return data
    }

    // MARK: - File size

    /// Returns the file size in bytes.
    func fileSize(at remotePath: String) async throws -> Int64 {
        guard let client else { throw SMBError.notConnected }
        let attrs = try await client.attributesOfItem(atPath: remotePath)
        if let size = attrs[.fileSizeKey] as? Int64 { return size }
        if let size = attrs[.fileSizeKey] as? Int { return Int64(size) }
        return 0
    }

    /// Bounded encoded image reads; media and documents use streams or disk downloads.
    func readFile(at remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        try await SMBFileRead.data(from: self, path: remotePath, progress: progress)
    }

    // MARK: - Download to file

    /// Downloads a file from the NAS to a local destination URL, reporting progress via a closure.
    func download(
        remotePath: String,
        to destination: URL,
        maxBytes: Int64 = SMBFileRead.maxTemporaryBytes,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let client else { throw SMBError.notConnected }
        let size = try await fileSize(at: remotePath)
        guard maxBytes > 0, size <= maxBytes else { throw SMBError.tooLarge(maxBytes) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        let control = SMBTransferControl(maxBytes: maxBytes)
        try await withTaskCancellationHandler {
            do {
                try await client.downloadItem(atPath: remotePath, to: staging) { completed, total in
                    guard control.accept(completed: completed, total: total) else { return false }
                    progress(total > 0 ? Double(completed) / Double(total) : 0)
                    return true
                }
            } catch {
                try control.check()
                throw error
            }
            try control.check()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Downloads documents and nonstreamable media to a unique, bounded temporary file.
    func temporaryFile(for remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let filename = URL(fileURLWithPath: remotePath).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASOpen", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent(filename)
        do {
            try await download(remotePath: remotePath, to: dest, progress: { progress?($0) })
            return dest
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }
}

// MARK: - Errors

enum SMBError: LocalizedError {
    case notConnected
    case invalidURL
    case invalidRange
    case tooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .notConnected: "NAS 未连接"
        case .invalidURL:   "无效的 NAS 地址"
        case .invalidRange: "文件读取范围无效"
        case .tooLarge(let limit): "文件超过加载上限（\(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))），请使用流式播放或先保存到本地"
        }
    }
}

protocol SMBRangeSource: Sendable {
    func fileSize(at path: String) async throws -> Int64
    func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data
}

enum SMBFileRead {
    static let chunkBytes = 512 * 1024
    static let maxMemoryBytes: Int64 = 32 * 1024 * 1024
    static let maxTemporaryBytes: Int64 = 500 * 1024 * 1024

    static func data(from source: any SMBRangeSource, path: String,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let size = try await source.fileSize(at: path)
        guard size >= 0, size <= maxMemoryBytes else { throw SMBError.tooLarge(maxMemoryBytes) }
        var result = Data()
        while result.count < size {
            try Task.checkCancellation()
            let length = min(chunkBytes, Int(size) - result.count)
            let chunk = try await source.readRange(at: path, offset: UInt64(result.count), length: length)
            guard chunk.count <= length else { throw SMBError.invalidRange }
            try Task.checkCancellation()
            result.append(chunk)
            progress?(Double(result.count) / Double(size))
            if chunk.count < length { break }
        }
        return result
    }
}

final class SMBTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int64
    private var cancelled = false
    private var exceeded = false
    init(maxBytes: Int64) { self.maxBytes = maxBytes }
    func cancel() { lock.withLock { cancelled = true } }
    func accept(completed: Int64, total: Int64) -> Bool {
        lock.withLock {
            exceeded = exceeded || completed > maxBytes || total > maxBytes
            return !cancelled && !exceeded
        }
    }
    func check() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            if exceeded { throw SMBError.tooLarge(maxBytes) }
        }
    }
}

// MARK: - FileManager helpers

// MARK: - Keychain helper

enum NASKeychain {
    private static let service = "com.easyreader.nas"

    static func save(password: String, for configID: UUID) {
        let account = configID.uuidString
        let data = Data(password.utf8)

        // Delete existing
        delete(for: configID)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for configID: UUID) -> String? {
        let account = configID.uuidString
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for configID: UUID) {
        let account = configID.uuidString
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
