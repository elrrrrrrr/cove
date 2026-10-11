import XCTest
import SwiftUI
import SwiftData
@testable import EasyReader

@MainActor final class DirectoryAndReadingIndexTests: XCTestCase {
    private func entries(_ name: String, count: Int = 1) -> [NASFileEntry] {
        (0..<count).map { .init(name: name + String($0), path: "/" + name + String($0), isDirectory: false, size: 100, modifiedAt: nil) }
    }
    func testDirectoryCacheUsesTTLAndManualRefresh() async throws {
        let cache = NASDirectoryCache(), counter = DirectoryProbe(), first = entries("first"), next = entries("next"), now = Date()
        let a = try await cache.load(path: "/", now: now) { await counter.hit(); return first }
        let b = try await cache.load(path: "/", now: now.addingTimeInterval(59)) { await counter.hit(); return next }
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        let c = try await cache.load(path: "/", now: now.addingTimeInterval(60)) { await counter.hit(); return next }
        XCTAssertEqual(c.map(\.id), next.map(\.id))
        _ = try await cache.load(path: "/", refresh: true, now: now.addingTimeInterval(61)) { await counter.hit(); return first }
        let hits = await counter.hits; XCTAssertEqual(hits, 3)
    }
    func testDirectoryBudgetsAndConnectionsAreIsolated() async throws {
        let cache = NASDirectoryCache(directoryLimit: 2, entryLimit: 3), other = NASDirectoryCache(), count = DirectoryProbe(), values = entries("file", count: 2)
        _ = try await cache.load(path: "/a") { await count.hit(); return values }
        _ = try await cache.load(path: "/b") { await count.hit(); return values }
        _ = try await cache.load(path: "/a") { await count.hit(); return values }
        _ = try await other.load(path: "/a") { await count.hit(); return values }
        await cache.clear()
        _ = try await cache.load(path: "/a") { await count.hit(); return values }
        let hits = await count.hits; XCTAssertEqual(hits, 5)
    }
    func testSharedDirectoryFetchCancellationAndStaleRefresh() async throws {
        let cache = NASDirectoryCache(), counter = DirectoryProbe(), old = entries("old"), current = entries("current")
        let fetch: @Sendable () async throws -> [NASFileEntry] = { await counter.hit(); try await Task.sleep(for: .milliseconds(100)); return old }
        let first = Task { try await cache.load(path: "/", fetch: fetch) }
        let second = Task { try await cache.load(path: "/", fetch: fetch) }
        try await Task.sleep(for: .milliseconds(30)); first.cancel()
        do { _ = try await first.value; XCTFail("取消的订阅必须结束") } catch is CancellationError {} catch { XCTFail(String(describing: error)) }
        let shared = try await second.value; XCTAssertEqual(shared.map(\.id), old.map(\.id))
        let hits = await counter.hits; XCTAssertEqual(hits, 1)
        let stale = Task { try await cache.load(path: "/", refresh: true, fetch: fetch) }
        try await Task.sleep(for: .milliseconds(20))
        let fresh = try await cache.load(path: "/", refresh: true) { current }
        do { _ = try await stale.value; XCTFail("旧刷新不能覆盖新刷新") } catch is CancellationError {} catch { XCTFail(String(describing: error)) }
        let cached = try await cache.load(path: "/") { XCTFail("应该使用新缓存"); return [] }
        XCTAssertEqual(fresh.map(\.id), cached.map(\.id)); XCTAssertEqual(cached.map(\.id), current.map(\.id))
    }
    func testTagPreparationKeepsUniqueOrderAndSerializationContract() throws {
        let item = ParsedItem(title: "项目", pageURL: URL(string: "https://media.example/")!, thumbnail: nil, duration: "", extra: " 演员 A,演员 B,演员 A, , 演员 C ")
        XCTAssertEqual(item.extraTags, ["演员 A", "演员 B", "演员 C"])
        let data = try JSONEncoder().encode(item), object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["title", "pageURL", "duration", "extra"])
        XCTAssertEqual(try JSONDecoder().decode(ParsedItem.self, from: data).extraTags, item.extraTags)
    }
    func testRecentProjectionDeduplicatesAddressesAndReadableTitles() {
        let records = [ReadingHistory(title: "/books/小说.txt", filePath: "/one"),
                       ReadingHistory(title: "小说", filePath: "/two"),
                       ReadingHistory(title: "另一个标题", filePath: "/two"),
                       ReadingHistory(title: "独立内容", url: "https://media.example/third")]
        let result = ReadingProjection.make(records.map(HistorySnapshot.init), includeGroups: false, now: Date(), calendar: .current)
        XCTAssertEqual(result.recent, [records[0].id, records[3].id])
        XCTAssertEqual(ReadingProjection.displayTitle("https://media.example/books/%E5%B0%8F%E8%AF%B4.epub"), "小说")
        XCTAssertEqual(ReadingProjection.displayTitle("/files/README"), "README")
    }
    func testDateGroupsFollowCalendarAndRetainRowsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 1))!
        let records = (0..<3).map { ReadingHistory(title: "\($0)") }
        records[0].lastReadAt = now; records[1].lastReadAt = now.addingTimeInterval(-7200); records[2].lastReadAt = now.addingTimeInterval(-3 * 86400)
        let output = ReadingProjection.make(records.map(HistorySnapshot.init), includeGroups: true, now: now, calendar: calendar)
        XCTAssertEqual(output.groups.map(\.title), ["今天", "昨天", "2026年10月5日"])
        XCTAssertEqual(output.groups.flatMap(\.ids), records.map(\.id))
        let tomorrow = ReadingProjection.make(records.map(HistorySnapshot.init), includeGroups: true, now: now.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(tomorrow.groups.first?.title, "昨天")
    }
    func testObserverUpdatesForModelEditsDeletesAndNewRecords() async throws {
        let container = try ModelContainer(for: ReadingHistory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene), index = ReadingIndex(includeGroups: true)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = UIHostingController(rootView: ReadingIndexObserver(index: index).equatable().modelContainer(container)); window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        let first = ReadingHistory(title: "第一项", url: "https://media.example/1"), second = ReadingHistory(title: "第二项", url: "https://media.example/2")
        container.mainContext.insert(first); container.mainContext.insert(second); try container.mainContext.save()
        try await until { index.recent.count == 2 }
        second.title = "第一项"; try container.mainContext.save()
        try await until { index.recent.count == 1 }
        second.title = "最新内容"; second.lastReadAt = Date().addingTimeInterval(1); try container.mainContext.save()
        try await until { index.latest?.id == second.id && index.recent.count == 2 }
        container.mainContext.delete(second); try container.mainContext.save()
        try await until { index.latest?.id == first.id && index.recent.count == 1 }
        container.mainContext.delete(first); try container.mainContext.save()
        try await until { index.latest == nil && index.groups.isEmpty }
    }
    func testLatestPreparationWinsDuringLargeHistoryUpdate() async throws {
        let index = ReadingIndex(includeGroups: true)
        let old = (0..<5000).map { ReadingHistory(title: "旧记录\($0)") }, current = ReadingHistory(title: "当前记录")
        index.update(old); index.update([current])
        try await until { index.recent.first?.id == current.id }
        XCTAssertEqual(index.recent.count, 1); XCTAssertEqual(index.groups.flatMap(\.items).map(\.id), [current.id])
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<120 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("索引没有按记录变化更新")
    }
}
private actor DirectoryProbe { private(set) var hits = 0; func hit() { hits += 1 } }
