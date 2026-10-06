import Foundation

actor ResourceAccess {
    static let shared = ResourceAccess()
    private let disk = DiskCache(root: CoveStorage.cache.appendingPathComponent("documents"), maxBytes: 1024 * 1024 * 1024, maxEntries: 128)
    private let slots = AsyncSlots(limit: 2)
    static let maxDocumentBytes: Int64 = 512 * 1024 * 1024

    func localFile(for item: ResourceItem, client: SMBClient? = nil, headers: [String: String] = [:], scope: String = "") async throws -> URL {
        let key = Self.key(item, headers: headers, scope: scope)
        if let cached = await disk.file(for: key) { return cached }
        guard (item.byteSize ?? 0) <= Self.maxDocumentBytes else { throw CoveError.message("文档超过 512 MB，请先在文件 App 中下载后打开") }
        guard await slots.acquire() else { throw CancellationError() }
        do {
            let file = try await transfer(item, client: client, headers: headers, key: key)
            await slots.release()
            return file
        } catch { await slots.release(); throw error }
    }
    private func transfer(_ item: ResourceItem, client: SMBClient?, headers: [String: String], key: String) async throws -> URL {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cove-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let client {
            let size = try await client.size(path: item.locator)
            guard size <= Self.maxDocumentBytes else { throw CoveError.message("文档超过 512 MB；视频和音乐请使用流式播放") }
            try await client.download(path: item.locator, to: temporary)
        } else {
            guard let url = URL(string: item.locator), ["http", "https"].contains(url.scheme ?? "") else { throw CoveError.message("下载地址无效") }
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let file = try await BoundedDownloader.download(request, maxBytes: Self.maxDocumentBytes)
            defer { try? FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: file, to: temporary)
        }
        try Task.checkCancellation()
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) <= Self.maxDocumentBytes else { throw CoveError.message("文件超过文档容量限制") }
        if let existing = await disk.file(for: key) { return existing }
        return try await disk.ingest(temporary, for: key, ttl: 7 * 86400, suffix: item.fileExtension)
    }
    static func key(_ item: ResourceItem, headers: [String: String], scope: String) -> String {
        StableHash.of(ScriptJSON.encode([item.id, item.revision, scope, ScriptJSON.encode(headers)]))
    }
    func clear() async throws { try await disk.clear() }
}
