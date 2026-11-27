import XCTest
import SwiftData
@testable import Cove

@MainActor
final class SiteStoreTests: XCTestCase {
    private var containers: [ModelContainer] = []

    private func context() throws -> ModelContext {
        let c = try ModelContainer(
            for: BookmarkSite.self, FavoriteVideo.self, ReadingHistory.self, OfflineItem.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(c)
        return ModelContext(c)
    }

    private func tempStore() -> SiteDefinitionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sites.json")
        return SiteDefinitionStore(storageURL: url)
    }

    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CoveTests." + UUID().uuidString)!
    }

    func testOnceOnlyInitializationAndDeletionNeverReseeds() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }

        let store = tempStore(), ctx = try context(), defaults = tempDefaults()
        store.initialize(context: ctx, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        let initialCount = try ctx.fetchCount(FetchDescriptor<BookmarkSite>())
        XCTAssertEqual(initialCount, 2)
        XCTAssertTrue(defaults.bool(forKey: SiteDefinitionStore.bootstrapKey))

        // Delete bookmarks and re-initialize on next launch -> must NOT reseed
        try ctx.delete(model: BookmarkSite.self); try ctx.save()
        let next = tempStore()
        next.initialize(context: ctx, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BookmarkSite>()), 0)
    }

    func testEntryIdentityPreservedOnReimport() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }

        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        let def = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
        let store = tempStore(), ctx = try context()

        try store.importDefinition(def, context: ctx)
        let firstBookmarks = try ctx.fetch(FetchDescriptor<BookmarkSite>())
        XCTAssertEqual(firstBookmarks.count, def.entries.count)
        let idsBefore = Set(firstBookmarks.map(\.id))

        try store.importDefinition(def, context: ctx)
        let secondBookmarks = try ctx.fetch(FetchDescriptor<BookmarkSite>())
        XCTAssertEqual(Set(secondBookmarks.map(\.id)), idsBefore)
    }
}
