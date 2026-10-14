import XCTest
import SwiftUI
import SwiftData
import WebKit
import AVFoundation
import CryptoKit
@testable import Cove

@MainActor final class ExampleShowcaseTests: XCTestCase {
    private func file(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("examples/" + path)
    }
    private func definition(_ name: String) throws -> SiteDefinition {
        try SiteDefinition.decode(String(contentsOf: file("sites/local-" + name + ".site"), encoding: .utf8))
    }
    private func extract(_ rule: SiteRule, page: String, path: String) async throws -> String {
        let browser = ExamplePage()
        let html = try String(contentsOf: file("local-demo/pages/" + page + ".html"), encoding: .utf8)
        try await browser.load(html, base: URL(string: "https://video.example" + path)!)
        let extraction = try XCTUnwrap(rule.extract)
        let result = try await WebScript.boundedString(extraction.javascript, in: browser.webView)
        return try XCTUnwrap(result)
    }
    private func items(_ string: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [[String: Any]])
    }
    func testLocalExamplesRoundTripWithoutCredentials() throws {
        for name in ["video", "comic", "journal", "directory"] {
            let value = try definition(name)
            XCTAssertEqual(value.schemaVersion, 1)
            XCTAssertEqual(try SiteDefinition.decode(value.yaml()), value)
            XCTAssertEqual(value.entries.count, 1)
            XCTAssertTrue(value.match.hosts?.contains("127.0.0.1") == true)
            XCTAssertTrue(value.rules.allSatisfy { $0.load?.headers == nil })
        }
    }
    func testTXTAutomaticallyBuildsChaptersAndPages() async throws {
        let url = try file("nas/files/Rust 学习指南.txt")
        let loaded = try await TextPaginator.load(url)
        var chapters = loaded.chapters
        XCTAssertEqual(chapters.count, 22)
        XCTAssertEqual(chapters.first?.title, "第1章 入门指南")
        XCTAssertEqual(chapters[1].title, "第2章 编写一个猜数字游戏")
        XCTAssertTrue(TextPaginator.detectChapters(in: "正文提到第3章 所有权，但这不是章标题。\n第六章将介绍枚举。\nChapter 2 Real heading\n").count == 1)
        let pages = await TextPaginator.paginate(text: loaded.text, font: .systemFont(ofSize: 17), lineSpacing: 8,
            containerSize: CGSize(width: 402, height: 778), insets: UIEdgeInsets(top: 60, left: 20, bottom: 80, right: 20), chapters: chapters)
        TextPaginator.assignPageIndices(chapters: &chapters, pages: pages)
        XCTAssertEqual(pages.map(\.text).joined(), loaded.text)
        XCTAssertGreaterThan(chapters[1].pageIndex, chapters[0].pageIndex)
        guard ProcessInfo.processInfo.environment["COVE_CAPTURE_SHOWCASE"] == "1" else { return }
        let oldTheme = UserDefaults.standard.object(forKey: AppTheme.storageKey)
        let oldMode = UserDefaults.standard.object(forKey: NovelReadingMode.storageKey)
        UserDefaults.standard.set("light", forKey: AppTheme.storageKey)
        UserDefaults.standard.set("paged", forKey: NovelReadingMode.storageKey)
        defer {
            for (key, value) in [(AppTheme.storageKey, oldTheme), (NovelReadingMode.storageKey, oldMode)] {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let container = try ModelContainer(for: FavoriteVideo.self, ReadingHistory.self, BookmarkSite.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let history = ReadingHistory(title: "Rust 学习指南", filePath: url.path, fileType: .txt,
            progress: Double(chapters[1].pageIndex) / Double(max(pages.count - 1, 1)))
        container.mainContext.insert(history)
        try await capture(NavigationStack { TXTReaderView(fileURL: url, historyItem: history) },
            name: "txt-reader", container: container, expectsPictures: false, minimumWait: .seconds(2))
        try await capture(TXTChapterList(chapters: chapters, onSelect: { _ in }),
            name: "txt-chapters", container: container, expectsPictures: false)
    }
    func testVideoExampleListPaginationSearchAndMediaAddress() async throws {
        let value = try definition("video"), rule = value.rules[0]
        let first = try items(await extract(rule, page: "videos", path: "/videos/"))
        XCTAssertEqual(first.count, 6); XCTAssertEqual(first[0]["title"] as? String, "山谷慢行")
        XCTAssertEqual(first[0]["url"] as? String, "https://video.example/watch/valley")
        XCTAssertEqual(first[0]["thumbnail"] as? String, "https://video.example/assets/valley.png")
        let nextItems = try items(await extract(rule, page: "videos-next", path: "/videos/?page=2"))
        XCTAssertEqual(nextItems.count, 2)
        let searchItems = try items(await extract(rule, page: "videos-search", path: "/videos/?q=山谷"))
        XCTAssertEqual(searchItems.count, 2)
        let page = ExamplePage(); try await page.load(String(contentsOf: file("local-demo/pages/videos.html"), encoding: .utf8), base: URL(string: "https://video.example/videos/")!)
        let parser = SiteParserRegistry.parser(definition: value, rule: rule)
        if case .webNavigation(let script) = parser.paginationMode {
            let next = try await WebScript.boundedString(script, in: page.webView)
            XCTAssertEqual(next, "https://video.example/videos/?page=2")
        } else { XCTFail("Expected a real next-page link") }
        let json = try await extract(value.rules[1], page: "video", path: "/watch/valley")
        let media = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(media["url"] as? String, "https://video.example/assets/demo.mp4")
    }
    func testComicExampleDetailsAndChaptersUseSameRules() async throws {
        let value = try definition("comic")
        let books = try items(await extract(value.rules[0], page: "comics", path: "/comics/"))
        XCTAssertEqual(books.count, 6)
        let detail = try await extract(value.rules[1], page: "comic", path: "/book/valley")
        let book = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
        XCTAssertEqual(book["title"] as? String, "山谷慢行")
        XCTAssertEqual((book["chapters"] as? [[String: Any]])?.count, 2)
        let chapter = try await extract(value.rules[2], page: "chapter", path: "/chapter/1")
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chapter.utf8)) as? [String: Any])
        XCTAssertEqual((content["images"] as? [String])?.count, 3)
        XCTAssertEqual(content["nextChapter"] as? String, "https://video.example/chapter/2")
    }
    func testJournalAndDirectoryExamplesKeepContentTypes() async throws {
        let journal = try definition("journal"), directory = try definition("directory")
        XCTAssertEqual(journal.rules[0].contentType, "article")
        let json = try await extract(journal.rules[1], page: "article", path: "/post/valley")
        let document = try ArticleDocument.decode(Data(json.utf8), base: URL(string: "https://video.example/post/valley")!, fallbackTitle: "")
        XCTAssertEqual(document.title, "山谷慢行"); XCTAssertTrue(document.blocks.contains { $0.kind == .image })
        XCTAssertEqual(directory.rules[0].contentType, "navLink")
        let folders = try items(await extract(directory.rules[0], page: "directory", path: "/directory/"))
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(directory.rule(for: URL(string: "http://127.0.0.1:8765/videos/")!, role: "catalog")?.contentType, "video")
    }
    func testCaptureProductionWebsiteAndSMBShowcase() async throws {
        guard ProcessInfo.processInfo.environment["COVE_CAPTURE_SHOWCASE"] == "1" else {
            throw XCTSkip("Optional showcase capture uses the owned localhost HTTP/SMB demo")
        }
        let definitions = try ["video", "comic", "journal", "directory"].map(definition)
        let library = SiteDefinitionStore.shared
        let previous = library.definitions
        try library.replace(definitions)
        XCTAssertEqual(SiteParserRegistry.parser(for: "http://127.0.0.1:8765/comics/", definitionID: "example.local.comic").galleryLayout, .portrait)
        let oldTheme = UserDefaults.standard.object(forKey: AppTheme.storageKey)
        UserDefaults.standard.set("light", forKey: AppTheme.storageKey)
        defer {
            do { try library.replace(previous) }
            catch { XCTFail("Failed to restore showcase configuration: \(error)") }
            if let oldTheme { UserDefaults.standard.set(oldTheme, forKey: AppTheme.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppTheme.storageKey) }
        }
        let container = try ModelContainer(for: FavoriteVideo.self, ReadingHistory.self, BookmarkSite.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for (name, title, path, id) in [("website-bento", "山海影库", "/videos/", "example.local.video"),
                                      ("website-comic", "漫游书架", "/comics/", "example.local.comic")] {
            let view = NavigationStack { SiteGalleryView(name: title, urlString: "http://127.0.0.1:8765" + path, definitionID: id) }
            try await capture(view, name: name, container: container, expectsPictures: true)
        }
        let client = SMBClient(config: NASConfig(name: "CoveDemo", host: "127.0.0.1:1445", port: 1445, username: "", shareName: "CoveDemo"))
        try await client.connect(password: "")
        let connection = NASConnection.smb(client)
        let all = try await client.listDirectory()
        XCTAssertTrue(all.contains { $0.fileType == .video }); XCTAssertTrue(all.contains { $0.fileType == .cbz })
        XCTAssertTrue(all.contains { $0.fileType == .txt }); XCTAssertTrue(all.contains { $0.fileType == .pdf })
        let names = ["赵雷 — 无法长大.jpg", "Rust 学习指南.epub", "山谷慢行.mp4", "沿海来信.jpg", "沿途音频.opus", "沿途绘本.cbz", "阅读空间.txt", "Cove 使用手记.pdf", "森林回声.jpg", "夜航手记.jpg", "城市漫游.jpg", "星际日记.jpg"]
        let entries = names.compactMap { name in all.first { $0.name == name } }
        for layout in [BrowserLayout.list, .bento] {
            try await capture(ExampleNAS(entries: entries, connection: connection, layout: layout), name: "nas-" + layout.rawValue,
                              container: container, expectsPictures: layout != .list)
        }
        await client.disconnect()
    }
    func testCaptureHackerNewsRustAndZhaoLei() async throws {
        guard ProcessInfo.processInfo.environment["COVE_CAPTURE_SHOWCASE"] == "1" else {
            throw XCTSkip("Optional reading showcase requires the localhost demo and public music preview")
        }
        let library = SiteDefinitionStore.shared, previous = library.definitions
        let oldTheme = UserDefaults.standard.object(forKey: AppTheme.storageKey)
        UserDefaults.standard.set("light", forKey: AppTheme.storageKey)
        defer {
            AudioPlayerManager.shared.stop()
            do { try library.replace(previous) } catch { XCTFail("Restore: \(error)") }
            if let oldTheme { UserDefaults.standard.set(oldTheme, forKey: AppTheme.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppTheme.storageKey) }
        }
        let yaml = try String(contentsOf: file("sites/hacker-news.site"), encoding: .utf8)
            .replacingOccurrences(of: "news.ycombinator.com", with: "127.0.0.1")
        let hn = try SiteDefinition.decode(yaml)
        try library.replace([hn])
        let container = try ModelContainer(for: FavoriteVideo.self, ReadingHistory.self, BookmarkSite.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try await capture(NavigationStack { SiteGalleryView(name: "Hacker News", urlString: "http://127.0.0.1:8765/news", definitionID: hn.id) },
            name: "hacker-news", container: container, expectsPictures: false, minimumWait: .seconds(3))
        let book = try file("nas/files/Rust 学习指南.epub")
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: file("showcase/rust-book-source.json"))) as? [String: String]
        let digest = SHA256.hash(data: try Data(contentsOf: book)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, source?["sha256"], "The captured book must match the pinned original EPUB")
        let reading = ReadingHistory(title: "Rust 学习指南", filePath: book.path, fileType: .epub, progress: 6.0 / 27.0)
        container.mainContext.insert(reading)
        try await capture(NavigationStack { EPUBReaderView(fileURL: book, historyItem: reading) },
            name: "rust-reader", container: container, expectsPictures: false, minimumWait: .seconds(2))

        let catalog = try JSONDecoder().decode(PreviewTrack.self, from: Data(contentsOf: file("showcase/zhaolei.json")))
        let item = AVPlayerItem(url: try XCTUnwrap(URL(string: catalog.previewUrl)))
        func tag(_ key: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem(); item.identifier = key; item.value = value; return item
        }
        item.externalMetadata = [tag(.commonIdentifierTitle, catalog.trackName as NSString),
            tag(.commonIdentifierArtist, catalog.artistName as NSString), tag(.commonIdentifierAlbumName, catalog.collectionName as NSString),
            tag(.commonIdentifierArtwork, try Data(contentsOf: file("showcase/zhaolei-cover.jpg")) as NSData)]
        let manager = AudioPlayerManager.shared
        manager.play(item: item, name: catalog.trackName, path: catalog.previewUrl)
        manager.player?.volume = 0
        for _ in 0..<200 where manager.artwork == nil || manager.duration == 0 || item.status != .readyToPlay {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(manager.title, "成都"); XCTAssertEqual(manager.artist, "赵雷")
        XCTAssertNotNil(manager.artwork); XCTAssertGreaterThan(manager.duration, 0); XCTAssertEqual(item.status, .readyToPlay)
        if manager.isPlaying { manager.togglePlay() }
        try await capture(NASAudioView(), name: "zhaolei-player", container: container, expectsPictures: false)
    }
    private func capture<V: View>(_ view: V, name: String, container: ModelContainer, expectsPictures: Bool, minimumWait: Duration = .zero) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let controller = UIHostingController(rootView: view.appAppearance().modelContainer(container))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: minimumWait)
        var screenshot: UIImage?
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(500))
            screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            if !expectsPictures { break }
            if try coverPixels(XCTUnwrap(screenshot)) > 80_000 { break }
        }
        let image = try XCTUnwrap(screenshot)
        if expectsPictures { XCTAssertGreaterThan(try coverPixels(image), 80_000, "Live thumbnails must render") }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func coverPixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = buffer.bindMemory(to: UInt8.self); var count = 0
            for i in stride(from: 0, to: values.count, by: 4) {
                let r = Int(values[i]), g = Int(values[i+1]), b = Int(values[i+2])
                // Cover colors count; monochrome chrome and blue fallback icons do not.
                if max(r, max(g, b)) - min(r, min(g, b)) > 25 && !(b > g + 15 && b > r + 15) { count += 1 }
            }
            return count
        }
    }
}

private struct PreviewTrack: Decodable {
    let trackName: String
    let artistName: String
    let collectionName: String
    let previewUrl: String
}

private struct ExampleNAS: View {
    let entries: [NASFileEntry]
    let connection: NASConnection
    @State var layout: BrowserLayout
    var body: some View {
        NavigationStack {
            NASDirectoryContent(entries: entries, layout: layout, connection: connection, isDownloading: false,
                readPathSet: [], totalCount: entries.count, onOpenDirectory: { _ in }, onOpen: { _ in }, onDownload: { _ in }, onLoadMore: {})
                .navigationTitle("CoveDemo · 资料库").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { BrowserLayoutMenu(layout: $layout) } }
                .appSurface()
        }
    }
}

@MainActor private final class ExamplePage: NSObject, WKNavigationDelegate {
    let webView = WKWebView()
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ html: String, base: URL) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation = $0; webView.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-eval'\">" + html, baseURL: base) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let value = continuation; continuation = nil; value?.resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let value = continuation; continuation = nil; value?.resume(throwing: error) }
}
