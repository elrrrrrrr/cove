import XCTest
import SwiftData
@testable import EasyReader

@MainActor final class SiteDefinitionTests: XCTestCase {
    private func fixture() throws -> SiteDefinition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        return try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
    }
    private var retainedContainers: [ModelContainer] = []
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: BookmarkSite.self, FavoriteVideo.self, ReadingHistory.self, NASConfig.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        retainedContainers.append(container)
        return ModelContext(container)
    }
    private func store() -> SiteDefinitionStore {
        SiteDefinitionStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sites.json"))
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CoveTests." + UUID().uuidString)! }

    func testYAMLRoundTripAndPathRouting() throws {
        let definition = try fixture()
        XCTAssertEqual(try SiteDefinition.decode(definition.yaml()), definition)
        XCTAssertEqual(definition.rule(for: URL(string: "https://media.example/books/")!, role: "catalog")?.contentType, "comic")
        XCTAssertEqual(definition.rule(for: URL(string: "https://media.example/latest/")!, role: "catalog")?.contentType, "video")
        XCTAssertNil(definition.rule(for: URL(string: "https://media.example/other/")!, role: "catalog"))
    }

    func testYAMLKeepsChineseReadableAndScriptsAsLiteralBlocks() throws {
        var definition = try fixture()
        definition.rules[0].extract = .init(script: "return [{title:'自定义内容',url:'https://media.example/watch/1'}];")
        let yaml = try definition.yaml()
        XCTAssertTrue(yaml.contains("自定义内容"))
        XCTAssertTrue(yaml.contains("script: |"))
        XCTAssertEqual(try SiteDefinition.decode(yaml), definition)
    }

    func testHostMatchingUsesDomainBoundaries() {
        let match = SiteMatch(hosts: ["media.example"], includeSubdomains: true)
        XCTAssertTrue(match.matches(URL(string: "https://media.example/")!))
        XCTAssertTrue(match.matches(URL(string: "https://cdn.media.example/")!))
        XCTAssertFalse(match.matches(URL(string: "https://media.example.attacker.example/")!))
        XCTAssertFalse(match.matches(URL(string: "https://notmedia.example/")!))
    }

    func testValidationRejectsTyposDuplicateKeysAndUnsupportedVersions() throws {
        let text = try fixture().yaml()
        XCTAssertThrowsError(try SiteDefinition.decode(text + "misspelled: true\n"))
        XCTAssertThrowsError(try SiteDefinition.decode(text + "id: duplicate\n"))
        var definition = try fixture(); definition.schemaVersion = 99
        XCTAssertThrowsError(try definition.validate())
        definition = try fixture(); definition.rules[0].extract?.script = "return [];"
        XCTAssertThrowsError(try definition.validate())
        definition = try fixture(); definition.match.hostPattern = "["
        XCTAssertThrowsError(try definition.validate())
    }

    func testEmptyFirstInstallationDoesNotReseedAfterDeletion() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let library = store(), context = try context(), defaults = defaults()
        library.initialize(context: context, freshInstall: true, defaults: defaults, bundle: Bundle(for: NSObject.self))
        // Main app can have local fixtures. A second invocation must never reimport anything.
        try context.delete(model: BookmarkSite.self); try context.save()
        let nextLaunch = SiteDefinitionStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sites.json"))
        nextLaunch.initialize(context: context, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertTrue(defaults.bool(forKey: SiteDefinitionStore.bootstrapKey))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 0)
        XCTAssertTrue(nextLaunch.definitions.isEmpty)
    }

    func testFreshInstallationImportsEntriesExactlyOnce() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let library = store(), context = try context(), defaults = defaults()
        library.initialize(context: context, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertEqual(library.definitions.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 2)
        let next = store()
        next.initialize(context: context, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 2)
    }

    func testInterruptedFreshInitializationRetriesInsteadOfBecomingAnUpgrade() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocked)
        let broken = SiteDefinitionStore(storageURL: blocked.appendingPathComponent("sites.json"))
        let context = try context(), defaults = defaults()
        broken.initialize(context: context, freshInstall: true, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertFalse(defaults.bool(forKey: SiteDefinitionStore.bootstrapKey))
        XCTAssertTrue(defaults.bool(forKey: SiteDefinitionStore.pendingBootstrapKey))
        let next = store()
        next.initialize(context: context, freshInstall: false, defaults: defaults, bundle: Bundle(for: Self.self))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 2)
        XCTAssertTrue(defaults.bool(forKey: SiteDefinitionStore.bootstrapKey))
        XCTAssertFalse(defaults.bool(forKey: SiteDefinitionStore.pendingBootstrapKey))
    }

    func testExistingReferencesAreLinkedWithoutAddingBookmarks() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let library = store(), context = try context()
        let bookmark = BookmarkSite(name: "我的入口", urlString: "https://media.example/latest/")
        bookmark.parserOverrides = SiteParserOverrides(extractItemsJS: "JSON.stringify([])")
        let favorite = FavoriteVideo(title: "旧收藏", pageURLString: "https://media.example/watch/1")
        let history = ReadingHistory(title: "旧历史", url: "https://media.example/watch/1", fileType: .video)
        context.insert(bookmark); context.insert(favorite); context.insert(history); try context.save()
        library.initialize(context: context, freshInstall: false, defaults: defaults(), bundle: Bundle(for: Self.self))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 1)
        XCTAssertEqual(bookmark.definitionID, "example.media")
        XCTAssertEqual(favorite.definitionID, "example.media")
        XCTAssertEqual(history.definitionID, "example.media")
        XCTAssertEqual(bookmark.parserOverrides?.extractItemsJS, "JSON.stringify([])")
    }

    func testImportReplaceAndCopyPreserveEntryIdentity() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let library = store(), context = try context()
        var definition = try fixture()
        try library.importDefinition(definition, context: context)
        let initialIDs = Set(try context.fetch(FetchDescriptor<BookmarkSite>()).map(\.id))
        definition.entries[0].path = "/latest/new/"
        try library.importDefinition(definition, context: context)
        let bookmarks = try context.fetch(FetchDescriptor<BookmarkSite>())
        XCTAssertEqual(Set(bookmarks.map(\.id)), initialIDs)
        XCTAssertTrue(bookmarks.contains { $0.urlString == "https://media.example/latest/new/" })
        try library.importDefinition(definition, context: context, asCopy: true)
        XCTAssertEqual(library.definitions.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 4)
    }

    func testCorruptImportDoesNotChangePersistedDefinitions() throws {
        let saved = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(saved) }
        let library = store(), context = try context()
        let definition = try fixture(); try library.importDefinition(definition, context: context)
        var invalid = definition; invalid.schemaVersion = 99
        XCTAssertThrowsError(try library.importDefinition(invalid, context: context))
        XCTAssertEqual(library.definitions, [definition])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkSite>()), 2)
    }

    func testFavoriteDataMergesWithoutDuplicatesAndRoundTrips() throws {
        let context = try context()
        let data = Data(#"{"schemaVersion":1,"favorites":[{"title":"收藏","pageURL":"https://media.example/watch/1"}]}"#.utf8)
        let file = try FavoriteDataFile.decode(data)
        try file.apply(to: context); try file.apply(to: context); try context.save()
        let values = try context.fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(try FavoriteDataFile.decode(FavoriteDataFile.export(values).json()).favorites.first?.id, values[0].id)
        let invalid = Data(#"{"schemaVersion":1,"favorites":[{"title":"无效","pageURL":"javascript:alert(1)"}]}"#.utf8)
        XCTAssertThrowsError(try FavoriteDataFile.decode(invalid))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FavoriteVideo>()), 1)
    }

    func testBackupPreservesSMBIdentityAndRejectsInvalidBeforeReplacing() throws {
        let context = try context()
        let config = NASConfig(name: "NAS", host: "nas.example", username: "reader", shareName: "books")
        context.insert(config); try context.save()
        let configID = config.id
        let backup = ConfigBackup.export(sites: [], nasConfigs: [config], fontSize: 17, theme: .system, blockerEnabled: true)
        try backup.apply(to: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NASConfig>()).first?.id, configID)
        var invalid = backup; invalid.schemaVersion = 99
        XCTAssertThrowsError(try invalid.apply(to: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NASConfig>()), 1)
    }

    func testBackupRoundTripUsesOnlyCurrentSchemaAndKeepsOverrides() throws {
        let context = try context()
        let site = BookmarkSite(name: "测试", urlString: "https://media.example/latest/", note: "说明", sortOrder: 4)
        site.parserOverrides = SiteParserOverrides(extractItemsJS: "return []; ")
        context.insert(site); try context.save()
        let backup = ConfigBackup.export(sites: [site], nasConfigs: [], fontSize: 18, theme: .dark, blockerEnabled: true)
        let file = try backup.writeToTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1); XCTAssertNil(json["version"])
        let loaded = try ConfigBackup.read(from: file)
        XCTAssertEqual(loaded.sites.first?.id, site.id)
        XCTAssertEqual(loaded.sites.first?.note, "说明")
        XCTAssertEqual(loaded.sites.first?.parserConfig?.extractItemsJS, "return []; ")
    }

    func testSingleSchemaExportsHaveNoExtraVersionField() throws {
        let definition = try fixture()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1); XCTAssertNil(json["version"])
        let favorites = try FavoriteDataFile.export([]).json()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: favorites) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1); XCTAssertNil(object["version"])
    }

    func testIncompleteSMBConfigRequiresSetup() {
        let config = NASConfig(name: "连接", host: "", port: 445, username: "reader", shareName: "")
        XCTAssertTrue(config.requiresSMBSetup)
        config.host = "nas.example"; config.port = 445; config.shareName = "media"
        XCTAssertFalse(config.requiresSMBSetup)
    }
}
