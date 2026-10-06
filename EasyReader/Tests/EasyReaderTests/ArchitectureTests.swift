import XCTest
import SwiftData
import WebKit
@testable import EasyReader

@MainActor final class ArchitectureTests: XCTestCase {
    private func fixture() throws -> SourceDefinition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        return try SourceDefinition.decode(String(contentsOf: url, encoding: .utf8))
    }
    private func sourceStore() -> SourceStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SourceStore(storageURL: root.appendingPathComponent("sources.json"), bindingURL: root.appendingPathComponent("folders.json"))
    }
    private func library() throws -> LibraryStore {
        let container = try ModelContainer(for: LibraryEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return LibraryStore(context: container.mainContext)
    }
    func testEditingChapterSelectorKeepsArrayAndNestedExtraction() async throws {
        var field = SelectorField(selector: ".old a", all: true)
        field.fields = ["title": SelectorField(), "url": SelectorField(attribute: "href")]
        XCTAssertEqual(field.editorShorthand, ".old a[]")
        let edited = field.editingShorthand(".chapters a[]")
        let module = PageModule(fields: ["chapters": edited])
        try module.validate(role: "comic")
        let engine = WebEngine()
        try await engine.load(URL(string: "data:text/html,<meta charset='utf-8'><div class='chapters'><a href='https://books.example/chapter/1'>第一章</a></div>")!)
        let json = try await engine.execute(module.javascript)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let chapters = try XCTUnwrap(object["chapters"] as? [[String: String]])
        XCTAssertEqual(chapters.first?["title"], "第一章")
        XCTAssertEqual(chapters.first?["url"], "https://books.example/chapter/1")
    }
    func testNewSchemaRoundTripsShorthandAndUnicode() throws {
        let source = try fixture()
        let yaml = try source.yaml()
        XCTAssertTrue(yaml.contains("示例媒体"))
        XCTAssertTrue(yaml.contains("a@href"))
        XCTAssertEqual(try SourceDefinition.decode(yaml), source)
        XCTAssertEqual(source.modules?.catalog?.fields?["tags"]?.all, true)
    }
    func testNewSchemaRejectsOldFormatUnknownFieldsAndDuplicates() throws {
        let yaml = try fixture().yaml()
        XCTAssertThrowsError(try SourceDefinition.decode(yaml + "version: 1\n"))
        XCTAssertThrowsError(try SourceDefinition.decode(yaml + "id: duplicate\n"))
        XCTAssertThrowsError(try SourceDefinition.decode(yaml.replacingOccurrences(of: "schemaVersion: 2", with: "schemaVersion: 1")))
        XCTAssertThrowsError(try SourceDefinition.decode(yaml.replacingOccurrences(of: "items:", with: "itmes:")))
    }
    func testInvalidArrayRulesFailBeforeUse() throws {
        var source = try fixture()
        source.modules?.chapter?.fields?["images"] = SelectorField(shorthand: "img@src")
        XCTAssertThrowsError(try source.validate())
        source = try fixture(); source.modules?.video?.script = "return {};"
        XCTAssertThrowsError(try source.validate())
    }
    func testRuleSelectionUsesOrderedPathVariants() throws {
        let source = try fixture()
        XCTAssertEqual(source.modules?.catalog?.selected(for: URL(string: "https://media.example/books/")!)?.kind, .comic)
        XCTAssertEqual(source.modules?.catalog?.selected(for: URL(string: "https://media.example/videos/")!)?.kind, .video)
        XCTAssertNil(source.modules?.chapter?.selected(for: URL(string: "https://media.example/book/1")!))
    }
    func testConfigFingerprintIsStableAndChangesWithRules() throws {
        var source = try fixture()
        XCTAssertEqual(source.fingerprint, try SourceDefinition.decode(source.yaml()).fingerprint)
        let before = source.fingerprint
        source.modules?.catalog?.fields?["title"] = SelectorField(shorthand: "h2")
        XCTAssertNotEqual(source.fingerprint, before)
    }
    func testResourceIdentitySeparatesSourcesAndSurvivesVersionChanges() {
        let first = ResourceItem(sourceID: "one", title: "a", locator: "comic.cbz", kind: .comic, byteSize: 12)
        var changed = first; changed.byteSize = 24; changed.modifiedAt = .now
        XCTAssertEqual(first.id, changed.id); XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertNotEqual(first.id, ResourceItem(sourceID: "two", title: "a", locator: "comic.cbz", kind: .comic).id)
        let transient = ResourceItem(sourceID: "one", title: "a", locator: "https://media.example/?token=new", kind: .video, identity: "video-1")
        XCTAssertEqual(transient.id, ResourceItem(sourceID: "one", title: "a", locator: "https://media.example/?token=old", kind: .video, identity: "video-1").id)
    }
    func testAllContentKindsAndArchiveFormatsAreIndependent() {
        XCTAssertEqual(ResourceKind.detect(path: "/book.cbz"), .comic)
        XCTAssertEqual(ResourceKind.detect(path: "/book.rar"), .comic)
        XCTAssertEqual(ResourceKind.detect(path: "/book.epub"), .ebook)
        XCTAssertEqual(ResourceKind.detect(path: "/book.pdf"), .ebook)
        XCTAssertEqual(ResourceKind.detect(path: "/book.txt"), .ebook)
        XCTAssertEqual(ResourceKind.detect(path: "/song.flac"), .audio)
        XCTAssertEqual(ResourceKind.detect(path: "/photo.heic"), .image)
        XCTAssertEqual(ResourceKind.detect(path: "/folder", isDirectory: true), .folder)
    }
    func testLibraryUpsertsFavoritesAndProgressAcrossEveryContentKind() throws {
        let library = try library()
        for kind in [ResourceKind.comic, .video, .audio, .ebook, .image, .web] {
            let item = ResourceItem(sourceID: "demo", title: kind.label, locator: kind.rawValue, kind: kind)
            let entry = try library.opened(item)
            entry.progress = 0.42; try library.persist()
            try library.toggleFavorite(item); try library.opened(item)
            XCTAssertTrue(library.favorites.contains(item.id))
            XCTAssertEqual(try library.entry(for: item).progress, 0.42)
        }
        XCTAssertEqual(library.entries.count, 6)
        let exported = try library.exportFavorites()
        try library.importFavorites(exported)
        XCTAssertEqual(library.entries.count, 6)
        XCTAssertEqual(library.favoriteItems.count, 6)
    }
    func testInvalidFavoriteImportDoesNotMutateLibrary() throws {
        let library = try library()
        let item = ResourceItem(sourceID: "demo", title: "保存", locator: "/one", kind: .comic)
        try library.toggleFavorite(item)
        XCTAssertThrowsError(try library.importFavorites(Data(#"{"schemaVersion":1,"items":[]}"#.utf8)))
        XCTAssertEqual(library.favorites, [item.id])
    }
    func testFilteredSourceReorderingPreservesOtherSlots() throws {
        let store = sourceStore()
        func source(_ id: String, _ adapter: SourceAdapter) -> SourceDefinition {
            SourceDefinition(id: id, name: id, source: SourceConnection(adapter: adapter, url: adapter == .web ? "https://media.example" : nil))
        }
        try store.replace([source("a1", .files), source("b1", .web), source("a2", .files), source("b2", .web)])
        try store.reorder(ids: ["a2", "a1"], visible: ["a1", "a2"])
        XCTAssertEqual(store.definitions.map(\.id), ["a2", "b1", "a1", "b2"])
    }
    func testOnceOnlyBootstrapDoesNotReseedDeletedSources() throws {
        let store = sourceStore(), library = try library()
        let defaults = UserDefaults(suiteName: "CoveBootstrap." + UUID().uuidString)!
        try store.bootstrap(library: library, bundle: Bundle(for: Self.self), defaults: defaults)
        XCTAssertEqual(store.definitions.count, 1)
        try store.remove(id: store.definitions[0].id)
        try store.bootstrap(library: library, bundle: Bundle(for: Self.self), defaults: defaults)
        XCTAssertTrue(store.definitions.isEmpty)
    }
    func testEmptyBootstrapStillCompletesOnce() throws {
        let store = sourceStore(), library = try library()
        let defaults = UserDefaults(suiteName: "CoveBootstrap." + UUID().uuidString)!
        try store.bootstrap(library: library, bundle: Bundle(for: NSObject.self), defaults: defaults)
        try store.bootstrap(library: library, bundle: Bundle(for: Self.self), defaults: defaults)
        XCTAssertTrue(store.definitions.isEmpty)
    }
    func testSearchEncodesQuerySeparatorsAndUnicodeAsOneValue() throws {
        let url = try SearchURL.resolve(template: "/search?q={query}", query: "猫&admin=true#extra", base: URL(string: "https://media.example")!)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: true))
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.value, "猫&admin=true#extra")
        XCTAssertNil(components.fragment)
    }
    func testEpisodeSelectionHasIndependentStableIdentity() throws {
        let item = ResourceItem(sourceID: "demo", title: "剧集", locator: "https://media.example/show/1", kind: .video, identity: "series", episodeCount: 3)
        let config = EpisodeModule(countField: "duration", url: "{url}?episode={episode}")
        let first = try EpisodeSelection.item(item, number: 1, config: config)
        let second = try EpisodeSelection.item(item, number: 2, config: config)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(second.locator.contains("episode=2"))
        XCTAssertThrowsError(try EpisodeSelection.item(item, number: 4, config: config))
    }
    func testWebSourceProfilesAreSeparatedAndSessionChangesInvalidateCacheScope() throws {
        let store = sourceStore()
        var source = try fixture(); source.id = "profile." + UUID().uuidString
        try store.save(source)
        let before = store.revisions[source.id]
        store.invalidateSession(id: source.id)
        XCTAssertNotEqual(before, store.revisions[source.id])
        XCTAssertNotEqual(SourceWebSession.store(id: "one").identifier, SourceWebSession.store(id: "two").identifier)
    }
    func testCSSShorthandNestedFieldsAndAsyncJSUseSameContract() async throws {
        let engine = WebEngine()
        let html = #"<meta charset="utf-8"><base href="https://media.example/"><article class="card"><h2 class="title">标题</h2><a href="/watch/1">链接</a><img data-src="/cover.jpg"><span class="tag">甲</span><span class="tag">乙</span></article>"#
        try await engine.load(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!)
        var module = PageModule(items: ".card", fields: ["title": .init(shorthand: ".title"), "url": .init(shorthand: "a@href"), "tags": .init(shorthand: ".tag[]")], kind: .video)
        let css = try await engine.execute(module.javascript)
        let items = try ResourceParser.catalog(css, sourceID: "demo", base: URL(string: "https://media.example/")!, defaultKind: .video)
        XCTAssertEqual(items.first?.title, "标题")
        XCTAssertEqual(items.first?.locator, "https://media.example/watch/1")
        XCTAssertEqual(items.first?.tags, ["甲", "乙"])
        module.fields = nil; module.items = nil
        module.script = "await Promise.resolve(); return [{title:'标题',url:'https://media.example/watch/1',tags:['甲','乙']}];"
        let js = try await engine.execute(module.javascript)
        XCTAssertEqual(try ResourceParser.catalog(js, sourceID: "demo", base: URL(string: "https://media.example/")!, defaultKind: .video), items)
        engine.cancel()
    }
    func testWebScriptTimeoutAndCancellationCompleteOnlyOnce() async throws {
        let engine = WebEngine()
        try await engine.load(URL(string: "data:text/html,<p>test</p>")!)
        do { _ = try await engine.execute("await new Promise(r=>setTimeout(r,200)); return 'late';", seconds: 0.01); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let task = Task { try await engine.execute("await new Promise(r=>setTimeout(r,200)); return 'late';") }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(250))
        let alive = try await engine.execute("return 'alive';")
        XCTAssertEqual(alive, "alive")
    }
    func testBundledContentPolicyCompilesAndKeepsNormalPageUsable() async throws {
        let engine = WebEngine()
        try await engine.load(URL(string: "data:text/html,<p>content</p>")!)
        let content = try await engine.execute("return document.querySelector('p').textContent;")
        XCTAssertEqual(content, "content")
    }
    func testOfflineLibraryUsesRelativePathsAndOpensWithoutSource() throws {
        let library = try library()
        let item = ResourceItem(sourceID: "removed", title: "离线图片", locator: "photo.png", kind: .image)
        let entry = try library.entry(for: item)
        let relative = "offline/" + UUID().uuidString + ".png"
        let file = try ContainedPath.resolve(relative, under: CoveStorage.data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        entry.offlineRelativePath = relative
        try library.persist()
        XCTAssertEqual(library.offlineItems.first?.id, item.id)
        guard case .image(let saved) = try ContentResolver.offline(item, library: library) else { return XCTFail("Expected offline image") }
        XCTAssertEqual(saved, file)
        XCTAssertFalse(relative.hasPrefix("/"))
    }
}
