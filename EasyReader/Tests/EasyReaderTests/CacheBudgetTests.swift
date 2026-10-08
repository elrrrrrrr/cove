import XCTest
@testable import EasyReader

@MainActor final class CacheBudgetTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testDiskCacheEvictsByBytesAndRecentUseWithoutRescanning() async throws {
        let root = try directory(), now = Date()
        let cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 10, ttl: 100)
        await cache.store(Data(count: 4), for: "aa", now: now)
        await cache.store(Data(count: 4), for: "bb", now: now.addingTimeInterval(1))
        let used = await cache.load("aa", now: now.addingTimeInterval(2)); XCTAssertNotNil(used)
        await cache.store(Data(count: 4), for: "cc", now: now.addingTimeInterval(3))
        let evicted = await cache.load("bb", now: now.addingTimeInterval(4)); XCTAssertNil(evicted)
        let bytes = await cache.usageBytes(), scans = await cache.scanCount
        XCTAssertEqual(bytes, 8); XCTAssertEqual(scans, 1)
        await cache.store(Data(count: 2), for: "aa", now: now.addingTimeInterval(5))
        let updated = await cache.usageBytes(); XCTAssertEqual(updated, 6)
        let restarted = DiskDataCache(root: root, suffix: ".cache", byteLimit: 10, ttl: 100)
        let loaded = await restarted.load("aa", now: now.addingTimeInterval(6)); XCTAssertEqual(loaded?.count, 2)
    }
    func testReadsDoNotExtendExpiryAndCountLimitIsEnforced() async throws {
        let root = try directory(), now = Date()
        let cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 100, countLimit: 2, ttl: 10)
        await cache.store(Data(count: 1), for: "aa", now: now)
        let fresh = await cache.load("aa", now: now.addingTimeInterval(9)); XCTAssertNotNil(fresh)
        let expired = await cache.load("aa", now: now.addingTimeInterval(11)); XCTAssertNil(expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("aa.cache").path))
        for (index, key) in ["bb", "cc", "dd"].enumerated() { await cache.store(Data(count: 1), for: key, now: now.addingTimeInterval(Double(index))) }
        let oldest = await cache.load("bb", now: now.addingTimeInterval(4)); XCTAssertNil(oldest)
        let bytes = await cache.usageBytes(); XCTAssertEqual(bytes, 2)
    }
    func testLegacySubdirectoriesAlsoCountTowardDiskBudget() async throws {
        let root = try directory(), legacy = root.appendingPathComponent("ab/page.jpg")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 20).write(to: legacy)
        let cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 10, ttl: 100)
        let total = await cache.usageBytes(); XCTAssertEqual(total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
    func testTraversalAndSymlinksCannotReadOrOverwriteOutsideCache() async throws {
        let root = try directory(), outside = try directory().appendingPathComponent("secret")
        let secret = Data("secret".utf8); try secret.write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("aa.cache"), withDestinationURL: outside)
        let cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 100, ttl: 100)
        let read = await cache.load("aa"); XCTAssertNil(read)
        await cache.store(Data("replace".utf8), for: "aa")
        await cache.store(Data("replace".utf8), for: "../secret")
        XCTAssertEqual(try Data(contentsOf: outside), secret)
        let bytes = await cache.usageBytes(); XCTAssertEqual(bytes, 0)
    }
    func testEntryLimitIsCheckedBeforeReadingFile() async throws {
        let root = try directory()
        try Data(count: 20).write(to: root.appendingPathComponent("aa.cache"))
        let cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 100, ttl: 100, entryByteLimit: 10)
        let data = await cache.load("aa"); XCTAssertNil(data)
        await cache.store(Data(count: 11), for: "bb")
        let bytes = await cache.usageBytes(); XCTAssertEqual(bytes, 0)
    }
    func testClearAllowsFreshWritesWithoutResurrectingOldFiles() async throws {
        let root = try directory(), cache = DiskDataCache(root: root, suffix: ".cache", byteLimit: 100, ttl: 100)
        await cache.store(Data(count: 5), for: "aa"); await cache.clear()
        let old = await cache.load("aa"); XCTAssertNil(old)
        await cache.store(Data(count: 7), for: "bb")
        let bytes = await cache.usageBytes(); XCTAssertEqual(bytes, 7)
    }
    func testGallerySnapshotsExpireAndCapacityDropsOldLists() async throws {
        let now = Date(), cache = GalleryCache(root: try directory(), ttl: 10, countLimit: 1)
        let first = URL(string: "https://media.example/a")!, second = URL(string: "https://media.example/b")!
        let items = [ParsedItem(title: "列表项目", pageURL: first, thumbnail: nil, duration: "", extra: "")]
        await cache.save(items, for: first, now: now)
        let fresh = await cache.load(for: first, now: now.addingTimeInterval(9)); XCTAssertEqual(fresh?.items.map(\.title), items.map(\.title))
        let expired = await cache.load(for: first, now: now.addingTimeInterval(11)); XCTAssertNil(expired)
        await cache.save(items, for: first, now: now)
        await cache.save(items, for: second, now: now.addingTimeInterval(1))
        let older = await cache.load(for: first, now: now.addingTimeInterval(2)); XCTAssertNil(older)
        let newest = await cache.load(for: second, now: now.addingTimeInterval(2)); XCTAssertEqual(newest?.items.map(\.title), items.map(\.title))
    }
}

@MainActor final class SharedImageWorkTests: XCTestCase {
    func testCancellingOneSubscriberDoesNotCancelAnother() async throws {
        let pool = SharedTaskPool<String, Int>(), probe = WorkProbe()
        let operation: @Sendable () async -> Int? = {
            await probe.start()
            do { try await Task.sleep(for: .milliseconds(120)) } catch { await probe.cancelled(); return nil }
            await probe.finish(); return 7
        }
        let a = Task { await pool.value(for: "same", operation: operation) }
        let b = Task { await pool.value(for: "same", operation: operation) }
        try await Task.sleep(for: .milliseconds(40)); a.cancel()
        let (first, second) = await (a.value, b.value)
        XCTAssertNil(first); XCTAssertEqual(second, 7)
        let count = await probe.starts, cancelled = await probe.cancellations
        XCTAssertEqual(count, 1); XCTAssertEqual(cancelled, 0)
    }
    func testLastSubscriberCancelsUnderlyingWorkAndRetryStartsFresh() async throws {
        let pool = SharedTaskPool<String, Int>(), probe = WorkProbe()
        let first = Task {
            await pool.value(for: "same") {
                await probe.start()
                do { try await Task.sleep(for: .seconds(10)) } catch { await probe.cancelled(); return nil }
                await probe.finish(); return 1
            }
        }
        for _ in 0..<100 { if await probe.starts > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        first.cancel(); let result = await first.value; XCTAssertNil(result)
        let again = await pool.value(for: "same") { 2 }; XCTAssertEqual(again, 2)
        for _ in 0..<100 { if await probe.cancellations > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        let cancellations = await probe.cancellations; XCTAssertEqual(cancellations, 1)
    }
    func testDecodeConcurrencyIsBoundedAndQueuedCancellationDoesNotLeakSlots() async throws {
        let limiter = AsyncWorkLimiter(limit: 2), probe = WorkProbe()
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await limiter.run {
                        await probe.start(); try? await Task.sleep(for: .milliseconds(20)); await probe.finish(); return 1
                    }
                }
            }
            for await value in group { XCTAssertEqual(value, 1) }
        }
        let peak = await probe.peak; XCTAssertEqual(peak, 2)
        let serial = AsyncWorkLimiter(limit: 1)
        let owner = Task { await serial.run { try? await Task.sleep(for: .milliseconds(100)); return 1 } }
        try await Task.sleep(for: .milliseconds(10))
        let queued = Task { await serial.run { 2 } }
        try await Task.sleep(for: .milliseconds(10)); queued.cancel()
        let cancelled = await queued.value; XCTAssertNil(cancelled)
        let completed = await owner.value; XCTAssertEqual(completed, 1)
        let next = await serial.run { 3 }; XCTAssertEqual(next, 3)
    }
}

private actor WorkProbe {
    private(set) var starts = 0
    private(set) var cancellations = 0
    private(set) var peak = 0
    private var active = 0
    func start() { starts += 1; active += 1; peak = max(peak, active) }
    func finish() { active -= 1 }
    func cancelled() { cancellations += 1; active -= 1 }
}
