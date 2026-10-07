import Foundation
import Security
import AMSMB2

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
    let host      : String
    let port      : Int
    let username  : String
    let shareName : String

    init(config: NASConfig) {
        host      = config.host
        port      = config.port
        username  = config.username
        shareName = config.shareName
    }
}

/// Wrapper around AMSMB2 providing async SMB2/3 file operations.
actor SMBClient {

    typealias FileEntry = NASFileEntry

    private var client: SMB2Manager?
    private let config: NASConfigSnapshot

    init(config: NASConfig) {
        self.config = NASConfigSnapshot(config: config)
    }

    init(snapshot: NASConfigSnapshot) {
        self.config = snapshot
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
        self.client = mgr
    }

    func disconnect() async {
        try? await client?.disconnectShare()
        client = nil
    }

    // MARK: - Directory listing

    func listDirectory(path: String = "/") async throws -> [FileEntry] {
        guard let client else { throw SMBError.notConnected }

        let contents = try await client.contentsOfDirectory(atPath: path)
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
        guard let client else { throw SMBError.notConnected }
        let range: Range<UInt64> = offset ..< (offset + UInt64(length))
        return try await client.contents(atPath: remotePath, range: range)
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

    // MARK: - Read file into memory

    /// Reads a remote file entirely into memory.
    func readFile(at remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        guard let client else { throw SMBError.notConnected }
        return try await client.contents(atPath: remotePath) { bytes, total in
            let pct = total > 0 ? Double(bytes) / Double(total) : 0
            progress?(pct)
            return true
        }
    }

    // MARK: - Download to file

    /// Downloads a file from the NAS to a local destination URL, reporting progress via a closure.
    func download(
        remotePath: String,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let client else { throw SMBError.notConnected }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await client.downloadItem(atPath: remotePath, to: destination) { completed, total -> Bool in
            let pct = total > 0 ? Double(completed) / Double(total) : 0
            progress(pct)
            return true   // continue
        }
    }

    // MARK: - Stream URL (for video — needs local file for AVPlayer)

    /// Downloads to temp and returns a local file URL for AVPlayer playback.
    func localURL(for remotePath: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let filename = URL(fileURLWithPath: remotePath).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASStream", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        try await download(remotePath: remotePath, to: dest, progress: { pct in
            progress?(pct)
        })
        return dest
    }
}

// MARK: - Errors

enum SMBError: LocalizedError {
    case notConnected
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notConnected: "NAS 未连接"
        case .invalidURL:   "无效的 NAS 地址"
        }
    }
}

// MARK: - FileManager helpers

extension FileManager {
    var offlineNASDirectory: URL {
        let docs = urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Offline/nas", isDirectory: true)
        try? createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var offlineWebDirectory: URL {
        let docs = urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Offline/web", isDirectory: true)
        try? createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}


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
