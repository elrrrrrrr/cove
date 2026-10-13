import XCTest
import SwiftData
import WebKit
@testable import EasyReader

@MainActor final class ArticleTests: XCTestCase {
    private let base = URL(string: "https://news.example/item?id=1")!
    private func definition() throws -> SiteDefinition {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try SiteDefinition.decode(String(contentsOf: root.appendingPathComponent("examples/sites/hacker-news.site"), encoding: .utf8))
    }
    private func fixture(_ name: String) throws -> String {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try String(contentsOf: root.appendingPathComponent("Articles/" + name), encoding: .utf8)
    }
    private func model() throws -> ModelContainer {
        try ModelContainer(for: FavoriteVideo.self, ReadingHistory.self, BookmarkSite.self, NASConfig.self, OfflineItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func execute(_ extraction: SiteExtraction, html: String) async throws -> Data {
        let page = ArticleTestPage()
        try await page.load(html, base: base)
        let result = try await WebScript.boundedString(extraction.javascript, in: page.webView)
        withExtendedLifetime(page) {}
        return Data(try XCTUnwrap(result).utf8)
    }

    func testCurrentSchemaRoundTripAndArticleControls() throws {
        let value = try definition(), decoded = try SiteDefinition.decode(value.yaml())
        XCTAssertEqual(value, decoded); XCTAssertEqual(value.schemaVersion, 1)
        let parser = SiteParserRegistry.parser(definition: value, rule: value.rules[0])
        XCTAssertEqual(parser.itemKind.stringValue, "article"); XCTAssertEqual(parser.galleryLayout, .list)
        XCTAssertNotNil(value.rule(for: URL(string: "https://news.ycombinator.com/item?id=1")!, role: "article"))
        XCTAssertNil(value.rule(for: URL(string: "https://articles.example/item?id=1")!, role: "article"))
        if case .bool = SiteFormSpec.kind("content", type: "field") {} else { XCTFail("Content must have a Boolean form control") }
        var invalid = value; invalid.rules[1].extract = .init(fields: ["title": .init(text: true)])
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try SiteField(selector: "main", attribute: "src", content: true).validate())
    }
    func testCSSProducesOrderedBlocksWithSafeInlineLinks() async throws {
        let html = """
        <article><p>Hello <a href="/reference">link</a>.</p><img src="/cover.png" alt="示例图">
        <h2>Heading</h2><blockquote><p>A quote</p></blockquote><pre>a\nb</pre>
        <script>secret()</script><style>hidden</style><iframe src="/tracking"></iframe><form>password</form>
        <p><a href="javascript:bad()">unsafe link</a></p></article>
        """
        let data = try await execute(.init(fields: ["title": .init(value: "示例"), "blocks": .init(selector: "article", content: true)]), html: html)
        let document = try ArticleDocument.decode(data, base: base, fallbackTitle: "fallback")
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .image, .heading, .quote, .code, .paragraph])
        XCTAssertEqual(String(document.blocks[0].text.characters), "Hello link.")
        XCTAssertTrue(document.blocks[0].text.runs.contains { $0.link == URL(string: "https://news.example/reference") })
        XCTAssertEqual(document.blocks[1].url?.absoluteString, "https://news.example/cover.png")
        XCTAssertEqual(document.blocks[1].alt, "示例图")
        XCTAssertEqual(document.blocks[2].level, 2)
        XCTAssertEqual(String(document.blocks[4].text.characters), "a\nb")
        XCTAssertFalse(document.blocks.last!.text.runs.contains { $0.link != nil })
        XCTAssertFalse(document.blocks.map { String($0.text.characters) }.joined().contains("password"))
    }
    func testJavaScriptAndCSSShareDocumentContract() async throws {
        let css = try await execute(.init(fields: ["title": .init(selector: "h1", text: true), "author": .init(value: "作者"), "blocks": .init(selector: "main", content: true)]), html: "<h1>标题</h1><main><p>正文</p></main>")
        let js = try await execute(.init(script: "return {title:'标题',author:'作者',blocks:[{type:'paragraph',text:'正文'}]};"), html: "<main></main>")
        XCTAssertEqual(try ArticleDocument.decode(css, base: base, fallbackTitle: ""), try ArticleDocument.decode(js, base: base, fallbackTitle: ""))
    }
    func testMissingUnsafeAndOversizedContentReportsError() throws {
        XCTAssertThrowsError(try ArticleDocument.decode(Data(#"{"blocks":[]}"#.utf8), base: base, fallbackTitle: ""))
        XCTAssertThrowsError(try ArticleDocument.decode(Data(#"{"blocks":[{"type":"iframe","url":"https://news.example"}]}"#.utf8), base: base, fallbackTitle: ""))
        XCTAssertThrowsError(try ArticleDocument.decode(Data(count: 2 * 1024 * 1024 + 1), base: base, fallbackTitle: ""))
        let blocks = Array(repeating: ["type":"paragraph","text":"a"], count: 2001)
        XCTAssertThrowsError(try ArticleDocument.decode(JSONSerialization.data(withJSONObject: ["blocks":blocks]), base: base, fallbackTitle: ""))
        for url in ["file:///private/data", "javascript:bad()", "https://user:password@news.example/a"] { XCTAssertNil(ArticleDocument.address(url, base: base)) }
    }
    func testUnsafeImagesAndLinksNeverBecomeNativeActions() throws {
        let data = Data(#"{"blocks":[{"type":"image","url":"file:///secret"},{"type":"link","text":"bad","url":"javascript:alert(1)"},{"type":"paragraph","runs":[{"text":"safe text","url":"file:///secret"}]}]}"#.utf8)
        let value = try ArticleDocument.decode(data, base: base, fallbackTitle: "标题")
        XCTAssertEqual(value.blocks.count, 1); XCTAssertFalse(value.blocks[0].text.runs.contains { $0.link != nil })
    }
    func testPublicHNExampleParsesSyntheticRowsAndNextLink() async throws {
        let value = try definition()
        let data = try await execute(try XCTUnwrap(value.rules[0].extract), html: fixture("catalog.html"))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["title"] as? String, "Ask HN: 你如何整理每天的阅读？")
        XCTAssertEqual(items[0]["url"] as? String, "https://news.example/item?id=1")
        XCTAssertEqual(items[0]["extra"] as? String, "demo_reader · 2 小时前")
        XCTAssertEqual(items[0]["duration"] as? String, "42 points")
        let page = ArticleTestPage(); try await page.load(fixture("catalog.html"), base: base)
        let parser = SiteParserRegistry.parser(definition: value, rule: value.rules[0])
        if case .webNavigation(let script) = parser.paginationMode {
            let next = try await WebScript.boundedString(script, in: page.webView)
            XCTAssertEqual(next, "https://news.example/item?p=2")
        } else { XCTFail("Expected nextLink") }
    }
    func testPublicHNTextDetailKeepsCommentsInOriginalPage() async throws {
        let extraction = try XCTUnwrap(definition().rules[1].extract)
        let data = try await execute(extraction, html: fixture("post.html"))
        let document = try ArticleDocument.decode(data, base: base, fallbackTitle: "fallback")
        XCTAssertEqual(document.author, "demo_reader")
        XCTAssertEqual(document.commentsURL, base)
        XCTAssertTrue(document.blocks.contains { $0.kind == .image })
        XCTAssertFalse(document.blocks.map { String($0.text.characters) }.joined().contains("演示评论保留"))
    }
    func testLinkPostCanOpenOriginalWithoutInventingBody() throws {
        let data = Data(#"{"title":"链接文章","sourceURL":"https://articles.example/story","blocks":[]}"#.utf8)
        let value = try ArticleDocument.decode(data, base: base, fallbackTitle: "")
        XCTAssertTrue(value.blocks.isEmpty); XCTAssertEqual(value.sourceURL?.host, "articles.example")
    }
    func testFavoritesRoundTripMergePinsAndOldKindsRemainUnchanged() throws {
        let container = try model(), context = container.mainContext
        let comic = FavoriteVideo(title: "漫画", pageURLString: "https://news.example/comic", isComic: true)
        let video = FavoriteVideo(title: "视频", pageURLString: "https://news.example/video")
        context.insert(comic); context.insert(video); try context.save()
        let item = ParsedItem(title: "文章", pageURL: base, thumbnail: nil, duration: "", extra: "站点")
        XCTAssertTrue(try ArticleReadingStore.toggleFavorite(item: item, title: item.title, definitionID: "sample", in: context))
        let article = try XCTUnwrap(ArticleReadingStore.favorite(for: base, in: context))
        try FavoritePins.set(article, pinned: true, context: context)
        let file = try FavoriteDataFile.decode(FavoriteDataFile.export(context.fetch(FetchDescriptor<FavoriteVideo>())).json())
        XCTAssertEqual(file.schemaVersion, 1); XCTAssertTrue(file.favorites.first { $0.id == article.id }?.isArticle == true)
        try file.apply(to: context); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FavoriteVideo>()), 3)
        XCTAssertTrue(comic.isComic); XCTAssertFalse(comic.isArticle); XCTAssertFalse(video.isArticle)
        XCTAssertEqual(FavoritePins.ordered(try context.fetch(FetchDescriptor<FavoriteVideo>())).first?.id, article.id)
        var invalid = file; invalid.favorites[0].isComic = true; invalid.favorites[0].isArticle = true
        XCTAssertThrowsError(try invalid.validate())
    }
    func testArticleTypeAndIdentitySurviveFullBackupAndFolderSync() throws {
        let container = try model(), context = container.mainContext
        let item = ParsedItem(title: "文章", pageURL: base, thumbnail: nil, duration: "", extra: "")
        let record = try ArticleReadingStore.save(item: item, title: "文章", definitionID: "sample", progress: 0.6, existing: nil, in: context)
        try ArticleReadingStore.toggleFavorite(item: item, title: "文章", definitionID: nil, in: context)
        let favorite = try XCTUnwrap(ArticleReadingStore.favorite(for: base, in: context))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SiteDefinitionStore(storageURL: root.appendingPathComponent("sites.json"))
        let backup = try ConfigBackup.decode(ConfigBackup.captureAll(context: context).json())
        try backup.applySynchronized(to: context, store: store)
        let restored = try XCTUnwrap(ArticleReadingStore.history(for: base, in: context))
        XCTAssertTrue(restored === record); XCTAssertEqual(restored.fileType, .article); XCTAssertEqual(restored.progress, 0.6)
        XCTAssertTrue(try ArticleReadingStore.favorite(for: base, in: context) === favorite)
        XCTAssertTrue(favorite.isArticle)
    }
    func testProgressUpdatesExistingRecordAndDoesNotReplaceWebHistory() throws {
        let container = try model(), context = container.mainContext
        let web = ReadingHistory(title: "原网页", url: base.absoluteString)
        context.insert(web); try context.save()
        let item = ParsedItem(title: "文章", pageURL: base, thumbnail: nil, duration: "", extra: "")
        let first = try ArticleReadingStore.save(item: item, title: "文章", definitionID: nil, progress: 0.3, existing: nil, in: context)
        let second = try ArticleReadingStore.save(item: item, title: "文章", definitionID: nil, progress: 0.7, existing: nil, in: context)
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(first.progress, 0.7)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReadingHistory>()), 2); XCTAssertEqual(web.fileType, .web)
    }
    func testBoundedScriptTimeoutCancellationAndLateCallback() async throws {
        let page = ArticleTestPage(); try await page.load("<main></main>", base: base)
        do {
            _ = try await WebScript.boundedString("new Promise(()=>{})", in: page.webView, timeout: .milliseconds(40))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let task = Task { try await WebScript.boundedString("new Promise(resolve=>setTimeout(()=>resolve('late'),150))", in: page.webView) }
        try await Task.sleep(for: .milliseconds(15)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(200))
        let alive = try await WebScript.boundedString("'still alive'", in: page.webView)
        XCTAssertEqual(alive, "still alive")
    }
    func testLoaderUsesDefaultCookiesAndConfiguredCSSThenCancels() async throws {
        let server = try ArticleFixtureServer(routes: ["/item":("text/html; charset=utf-8", Data(try fixture("post.html").utf8))])
        var value = try definition(); value.match.hosts = ["127.0.0.1"]; value.rules[1].match?.hosts = ["127.0.0.1"]
        let previous = SiteParserRegistry.definitions; defer { SiteParserRegistry.replaceDefinitions(previous) }
        SiteParserRegistry.replaceDefinitions([value])
        let loader = ArticleLoader()
        XCTAssertTrue(loader.webView.configuration.websiteDataStore.isPersistent)
        loader.load(url: URL(string: server.url + "/item?id=1")!, title: "原标题", definitionID: value.id)
        try await wait { if case .loaded = loader.state { return true }; return false }
        if case .loaded(let document) = loader.state { XCTAssertEqual(document.author, "demo_reader") }
        else { XCTFail("Expected native document") }
        loader.cancel(); XCTAssertFalse(loader.webView.isLoading)
    }
    func testHTTPErrorsCannotPublishNativeDocument() async throws {
        let server = try ArticleFixtureServer(routes: [:])
        let loader = ArticleLoader(); loader.load(url: URL(string: server.url + "/missing")!, title: "404", definitionID: nil)
        XCTAssertTrue(loader.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        try await wait { if case .failed = loader.state { return true }; return false }
        if case .failed(let message) = loader.state { XCTAssertTrue(message.contains("404"), message) }
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out"); throw URLError(.timedOut)
    }
}

@MainActor private final class ArticleTestPage: NSObject, WKNavigationDelegate {
    let webView = WKWebView()
    private var pending: CheckedContinuation<Void, Error>?
    func load(_ html: String, base: URL) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            webView.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-eval'\">" + html, baseURL: base)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let pending = self?.pending else { return }; self?.pending = nil
                pending.resume(throwing: URLError(.timedOut))
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pending?.resume(); pending = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pending?.resume(throwing: error); pending = nil }
}
