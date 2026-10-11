import XCTest
import SwiftData
@testable import EasyReader

@MainActor final class SiteConfigurationSaveTests: XCTestCase {
    private func fixture() throws -> SiteDefinition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        return try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
    }
    func testExplicitEntryEditsPreserveUUIDAndDoNotReseedDeletedEntries() throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let container = try ModelContainer(for: BookmarkSite.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let store = SiteDefinitionStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sites.json"))
        var value = try fixture()
        try store.save(value); store.addEntries(value, context: context); try context.save()
        let rows = try context.fetch(FetchDescriptor<BookmarkSite>())
        let primary = try XCTUnwrap(rows.first { $0.entryID == "latest" })
        let removed = try XCTUnwrap(rows.first { $0.entryID == "books" })
        let id = primary.id
        primary.name = "我的自定义名称"; context.delete(removed); try context.save()
        value.entries[0].path = "/search/new/"; value.entries[0].category = "comic"
        try store.saveConfiguration(value, for: primary, context: context)
        XCTAssertEqual(primary.id, id)
        XCTAssertEqual(primary.name, "我的自定义名称")
        XCTAssertEqual(primary.urlString, "https://media.example/search/new/")
        XCTAssertEqual(primary.category, .comic)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 1)
        value.entries[0].name = "改名入口"
        value.entries.append(.init(id: "added", name: "新增入口", path: "/latest/", category: "video"))
        try store.saveConfiguration(value, for: primary, context: context)
        XCTAssertEqual(primary.name, "改名入口"); XCTAssertEqual(primary.id, id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 2)
        XCTAssertFalse(try context.fetch(FetchDescriptor<BookmarkSite>()).contains { $0.entryID == "books" })
        withExtendedLifetime(container) {}
    }
    func testFailedConfigurationWriteLeavesExistingBookmarkAndIdentityUntouched() throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let value = try fixture(); SiteParserRegistry.replaceDefinitions([value])
        let container = try ModelContainer(for: BookmarkSite.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let site = BookmarkSite(name: "原名称", urlString: "https://media.example/latest/")
        site.definitionID = value.id; site.entryID = "latest"; context.insert(site); try context.save()
        let id = site.id
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let store = SiteDefinitionStore(storageURL: blocked.appendingPathComponent("sites.json"))
        var edited = value; edited.entries[0].name = "不应保存"; edited.entries[0].path = "/changed/"
        XCTAssertThrowsError(try store.saveConfiguration(edited, for: site, context: context))
        XCTAssertEqual(site.name, "原名称"); XCTAssertEqual(site.urlString, "https://media.example/latest/"); XCTAssertEqual(site.id, id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 1)
        withExtendedLifetime(container) {}
    }
}
