import Foundation
import AMSMB2

struct RemoteEntry: Sendable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date?
}

private final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

actor SMBClient: RangeReader {
    private var manager: SMB2Manager?
    private let connection: SourceConnection
    private let password: String
    init(connection: SourceConnection, password: String) { self.connection = connection; self.password = password }
    private func connected() async throws -> SMB2Manager {
        if let manager { return manager }
        guard let host = connection.host, let share = connection.share,
              let url = URL(string: "smb://" + host),
              let manager = SMB2Manager(url: url, credential: URLCredential(user: connection.username ?? "", password: password, persistence: .forSession)) else {
            throw CoveError.message("SMB 地址无效")
        }
        try await manager.connectShare(name: share)
        self.manager = manager
        return manager
    }
    func list(path: String) async throws -> [RemoteEntry] {
        let manager = try await connected()
        let contents = try await manager.contentsOfDirectory(atPath: path)
        try Task.checkCancellation()
        return contents.compactMap { item in
            guard let name = item[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            let size = (item[.fileSizeKey] as? Int64) ?? Int64((item[.fileSizeKey] as? Int) ?? 0)
            return RemoteEntry(name: name, path: (path as NSString).appendingPathComponent(name),
                               isDirectory: item[.fileResourceTypeKey] as? URLFileResourceType == .directory,
                               size: size, modifiedAt: item[.contentModificationDateKey] as? Date)
        }
    }
    func size(path: String) async throws -> Int64 {
        let manager = try await connected()
        let attributes = try await manager.attributesOfItem(atPath: path)
        return (attributes[.fileSizeKey] as? Int64) ?? Int64((attributes[.fileSizeKey] as? Int) ?? 0)
    }
    func readRange(path: String, offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard length > 0, length <= 512 * 1024, offset <= UInt64.max - UInt64(length) else {
            throw CoveError.message("文件读取范围无效")
        }
        let manager = try await connected()
        let result = try await manager.contents(atPath: path, range: offset ..< offset + UInt64(length))
        try Task.checkCancellation()
        return result
    }
    func download(path: String, to destination: URL) async throws {
        let manager = try await connected()
        let cancellation = TransferCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await manager.downloadItem(atPath: path, to: destination) { _, _ in !cancellation.isCancelled }
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }
    func disconnect() async {
        try? await manager?.disconnectShare()
        manager = nil
    }
}
