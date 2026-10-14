import XCTest
import Network
import SwiftData
@testable import Cove

@MainActor final class OfflineDownloadTests: XCTestCase {
    private func files() throws -> OfflineFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = OfflineFiles(dataRoot: root.appendingPathComponent("Support/Cove/data"), documentsRoot: root.appendingPathComponent("Documents"))
        try FileManager.default.createDirectory(at: files.dataRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.documentsRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return files
    }
    private func settled(_ manager: DownloadManager) async throws {
        for _ in 0..<300 { if manager.activeCount == 0 { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("下载队列没有结束")
    }
    private func regularFiles(_ root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    func testHTTPStatusFailuresNeverPublishFilesAndRetrySucceedsOnce() async throws {
        let server = try OfflineHTTPServer { count in .init(status: count == 1 ? 404 : 200, body: Data("离线小说".utf8)) }; defer { server.stop() }
        let files = try files(), manager = DownloadManager(files: files)
        let id = try XCTUnwrap(manager.add(title: "小说", sourceURL: server.url.absoluteString, fileType: .txt))
        try await settled(manager)
        guard case .failed(let message) = manager.downloads.first?.state else { return XCTFail("404 不应成功") }
        XCTAssertTrue(message.contains("404")); XCTAssertTrue(manager.pendingPersist.isEmpty); XCTAssertTrue(regularFiles(files.root).isEmpty)
        manager.retry(id: id); try await settled(manager)
        let completed = try XCTUnwrap(manager.downloads.first)
        XCTAssertEqual(completed.id, id); XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(completed.localPath.hasPrefix("Offline/web/")); XCTAssertFalse(completed.localPath.contains(files.dataRoot.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.url(for: completed.localPath))), Data("离线小说".utf8))
        XCTAssertEqual(manager.drainPendingPersist().count, 1); XCTAssertTrue(manager.drainPendingPersist().isEmpty)
        manager.retry(id: id); XCTAssertEqual(server.count.value, 2)
    }
    func testHTTPKnownAndUnknownSizeLimitsCancelAndCleanPartialFiles() async throws {
        for unknown in [false, true] {
            let server = try OfflineHTTPServer { _ in .init(body: Data(count: 8192), chunked: unknown) }; defer { server.stop() }
            let files = try files(), manager = DownloadManager(files: files, limit: 128)
            manager.add(title: "超限", sourceURL: server.url.absoluteString, fileType: .txt)
            try await settled(manager)
            guard case .failed = manager.downloads.first?.state else { return XCTFail("超限文件不能发布") }
            XCTAssertTrue(manager.pendingPersist.isEmpty); XCTAssertTrue(regularFiles(files.root).isEmpty)
        }
    }
    func testUnsupportedURLCannotReadLocalFiles() async throws {
        let files = try files(), manager = DownloadManager(files: files)
        manager.add(title: "无效", sourceURL: "file:///etc/hosts", fileType: .txt)
        try await settled(manager)
        guard case .failed = manager.downloads.first?.state else { return XCTFail("本地 URL 不能进入 HTTP 下载") }
        XCTAssertTrue(regularFiles(files.root).isEmpty); XCTAssertTrue(manager.pendingPersist.isEmpty)
    }
    func testRetryWaitsForPreviousAttemptAndRejectsItsLateProgressAndFile() async throws {
        let source = OfflineNASFixture(identity: "server", delay: 0.08), files = try files()
        let manager = DownloadManager(files: files, maxConcurrent: 1); manager.configureSMB(client: source)
        let id = try XCTUnwrap(manager.add(title: "文件", sourceURL: "/file.txt", fileType: .txt, isNAS: true))
        for _ in 0..<100 { if await source.calls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        manager.retry(id: id)
        XCTAssertEqual(manager.downloads.first?.state, .pending)
        try await settled(manager)
        let item = try XCTUnwrap(manager.downloads.first), file = try XCTUnwrap(files.url(for: item.localPath))
        XCTAssertEqual(item.state, .completed); XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "server:2")
        let peak = await source.peak, calls = await source.calls; XCTAssertEqual(peak, 1); XCTAssertEqual(calls, 2)
        XCTAssertEqual(regularFiles(files.root).count, 1); XCTAssertEqual(manager.pendingPersist.count, 1)
    }
    func testSameNASPathOnDifferentConnectionsDoesNotDeduplicateOrOverwrite() async throws {
        let files = try files(), manager = DownloadManager(files: files)
        let a = OfflineNASFixture(identity: "a", delay: 0.03), b = OfflineNASFixture(identity: "b", delay: 0.03)
        manager.configureSMB(client: a); let first = try XCTUnwrap(manager.add(title: "同名", sourceURL: "/same.txt", fileType: .txt, isNAS: true))
        manager.configureSMB(client: b); let second = try XCTUnwrap(manager.add(title: "同名", sourceURL: "/same.txt", fileType: .txt, isNAS: true))
        XCTAssertNotEqual(first, second); try await settled(manager)
        let batch = manager.drainPendingPersist(); XCTAssertEqual(batch.count, 2)
        let contents = try batch.map { try String(contentsOf: XCTUnwrap(files.url(for: $0.localPath)), encoding: .utf8) }
        XCTAssertEqual(Set(contents), ["a:1", "b:1"]); XCTAssertEqual(Set(batch.map(\.localPath)).count, 2)
    }
    func testCancelReleasesQueueSlotOnlyAfterCleanupAndStartsNext() async throws {
        let files = try files(), source = OfflineNASFixture(identity: "server", delay: 0.06), manager = DownloadManager(files: files, maxConcurrent: 1)
        manager.configureSMB(client: source)
        let cancelled = try XCTUnwrap(manager.add(title: "取消", sourceURL: "/cancel.txt", fileType: .txt, isNAS: true))
        manager.add(title: "保留", sourceURL: "/next.txt", fileType: .txt, isNAS: true)
        try await Task.sleep(for: .milliseconds(10)); manager.cancel(id: cancelled)
        try await settled(manager)
        XCTAssertEqual(manager.downloads.count, 1); XCTAssertEqual(manager.downloads.first?.state, .completed)
        XCTAssertEqual(manager.pendingPersist.count, 1); XCTAssertEqual(regularFiles(files.root).count, 1)
        let peak = await source.peak; XCTAssertEqual(peak, 1)
    }
    func testClearWaitsForCancelledWorkWithoutResurrectingDownloads() async throws {
        let files = try files(), source = OfflineNASFixture(identity: "server", delay: 0.05), manager = DownloadManager(files: files)
        manager.configureSMB(client: source); manager.add(title: "取消", sourceURL: "/cancel.txt", fileType: .txt, isNAS: true)
        try await Task.sleep(for: .milliseconds(10)); await manager.clear(); try files.clear()
        XCTAssertTrue(manager.downloads.isEmpty); XCTAssertTrue(manager.pendingPersist.isEmpty)
        XCTAssertEqual(manager.activeCount, 0); XCTAssertTrue(regularFiles(files.root).isEmpty)
        manager.add(title: "恢复", sourceURL: "/next.txt", fileType: .txt, isNAS: true)
        try await settled(manager); XCTAssertEqual(manager.downloads.first?.state, .completed)
    }
    func testContainerRebasingMigrationPreservesRecordsIDsAndContents() async throws {
        let files = try files(), old = files.documentsRoot.appendingPathComponent("Offline/nas/小说.txt")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("旧收藏资源".utf8).write(to: old)
        let container = try ModelContainer(for: OfflineItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = OfflineItem(title: "小说", localPath: "/old-container/Documents/Offline/nas/小说.txt", fileType: .txt, fileSizeBytes: 123)
        let id = item.id, date = item.savedAt
        container.mainContext.insert(item); try container.mainContext.save()
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.url(for: item.localPath)), encoding: .utf8), "旧收藏资源")
        try files.migrateLegacyDirectory(); try await files.normalizeRecords(in: container.mainContext)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.historyURL(for: "/old-container/Documents/Offline/nas/小说.txt")), encoding: .utf8), "旧收藏资源")
        XCTAssertEqual(item.localPath, "Offline/nas/小说.txt"); XCTAssertEqual(item.id, id); XCTAssertEqual(item.savedAt, date); XCTAssertEqual(item.fileSizeBytes, 123)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.url(for: item.localPath)), encoding: .utf8), "旧收藏资源")
        try files.migrateLegacyDirectory(); try await files.normalizeRecords(in: container.mainContext)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<OfflineItem>()).count, 1)
    }
    func testLegacyMigrationConflictsPreserveBothCopiesAndReadOriginal() throws {
        let files = try files(), old = files.documentsRoot.appendingPathComponent("Offline/nas/same.txt"), new = files.root.appendingPathComponent("nas/same.txt")
        for file in [old, new] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("旧文件".utf8).write(to: old); try Data("新文件".utf8).write(to: new)
        try files.migrateLegacyDirectory()
        let path = "/old-container/Documents/Offline/nas/same.txt"
        XCTAssertNil(files.normalizedPath(path))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.url(for: path)), encoding: .utf8), "旧文件")
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "新文件")
    }
    func testOfflinePathsRejectTraversalAndSymlinksAndUnsafeNames() throws {
        let files = try files(), outside = files.dataRoot.appendingPathComponent("Cove.store")
        try Data("数据库".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("linked.txt"), withDestinationURL: outside)
        XCTAssertNil(files.url(for: "Offline/../Cove.store")); XCTAssertNil(files.historyURL(for: "Offline/../Cove.store")); XCTAssertNil(files.url(for: "Offline/linked.txt"))
        XCTAssertNil(files.url(for: outside.path)); files.deleteFile(path: "Offline/linked.txt")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "数据库")
        let dest = try files.destination(id: UUID(), attempt: UUID(), isNAS: false, source: "https://media.example/%2E%2E%2Fevil.txt", type: .txt)
        XCTAssertTrue(try files.relativePath(dest).hasPrefix("Offline/web/")); XCTAssertFalse(dest.lastPathComponent.contains("/"))
    }
}

private actor OfflineNASFixture: OfflineDownloadSource {
    nonisolated let cacheIdentity: String
    let delay: TimeInterval
    private(set) var calls = 0
    private(set) var peak = 0
    private var active = 0
    init(identity: String, delay: TimeInterval) { cacheIdentity = identity; self.delay = delay }
    func download(remotePath: String, to file: URL, maxBytes: Int64, progress: @Sendable @escaping (Double) -> Void) async throws {
        calls += 1; active += 1; peak = max(peak, active); let call = calls
        defer { active -= 1 }
        // Intentionally ignores cancellation so the queue must reject late completion itself.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() } }
        progress(0.95)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(cacheIdentity):\(call)".utf8).write(to: file)
    }
}

private final class OfflineHTTPServer: @unchecked Sendable {
    struct Response: Sendable { var status = 200; var body: Data; var chunked = false }
    let listener: NWListener
    let count = ImageRequestCounter()
    let url: URL
    private let tracked = OfflineHTTPConnections()
    init(response: @escaping @Sendable (Int) -> Response) throws {
        let ready = DispatchSemaphore(value: 0), queue = DispatchQueue(label: "CoveOfflineHTTP")
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let counter = count, tracked = tracked
        listener.newConnectionHandler = { connection in
            tracked.add(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                counter.increment(); let value = response(counter.value)
                let size = value.chunked ? "Transfer-Encoding: chunked" : "Content-Length: \(value.body.count)"
                let headers = "HTTP/1.1 \(value.status) Result\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\n\(size)\r\nConnection: close\r\n\r\n"
                let bytes = value.chunked ? Data("\(String(value.body.count, radix: 16))\r\n".utf8) + value.body + Data("\r\n0\r\n\r\n".utf8) : value.body
                connection.send(content: Data(headers.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { throw URLError(.cannotConnectToHost) }
        url = URL(string: "http://127.0.0.1:\(port.rawValue)/file.txt")!

    }
    func stop() { listener.cancel(); tracked.stop() }
}

private final class OfflineHTTPConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    func add(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    func stop() { lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() } }
}
