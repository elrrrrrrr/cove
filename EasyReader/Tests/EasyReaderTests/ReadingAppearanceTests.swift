import XCTest
import SwiftUI
import SwiftData
import WebKit
@testable import EasyReader

@MainActor final class ReadingAppearanceTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var containers: [ModelContainer] = []
    private var saved: [String: Any] = [:]
    private let keys = [AppTheme.storageKey, NovelReadingMode.storageKey, "readerFontSize"]
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
            UserDefaults.standard.set("system", forKey: AppTheme.storageKey)
            UserDefaults.standard.set("paged", forKey: NovelReadingMode.storageKey)
            UserDefaults.standard.set(17, forKey: "readerFontSize")
        }
    }
    override func tearDown() async throws {
        await MainActor.run {
            for window in windows { window.rootViewController = nil; window.isHidden = true }
            windows.removeAll(); containers.removeAll()
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try await super.tearDown()
    }
    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 320, height: 700)) throws -> UIHostingController<AnyView> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: AnyView(view))
        window.rootViewController = controller; window.makeKeyAndVisible(); windows.append(window)
        return controller
    }
    private func snapshot(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func descendant<T: UIView>(_ view: UIView, as type: T.Type) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews { if let value = descendant(child, as: type) { return value } }
        return nil
    }
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: BookmarkSite.self, FavoriteVideo.self, ReadingHistory.self, OfflineItem.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container); return container.mainContext
    }
    func testGlobalThemeChangesNativeHomeAndSettings() async throws {
        let context = try context()
        let site = BookmarkSite(name: "示例站点", urlString: "https://media.example/", category: .video)
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        site.faviconData = icon.pngData(); context.insert(site); try context.save()
        let controller = try host(ContentView().modelContainer(context.container).appAppearance())
        for theme in [AppTheme.dark, .light, .sepia] {
            UserDefaults.standard.set(theme.rawValue, forKey: AppTheme.storageKey)
            try await Task.sleep(for: .milliseconds(150))
            snapshot(controller.view, name: "home-" + theme.rawValue)
            XCTAssertEqual(controller.traitCollection.userInterfaceStyle, theme == .dark ? .dark : .light)
        }
        let settings = try host(SettingsView().modelContainer(context.container).appAppearance())
        UserDefaults.standard.set("dark", forKey: AppTheme.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        snapshot(settings.view, name: "settings-dark")
        XCTAssertEqual(settings.traitCollection.userInterfaceStyle, .dark)
        UserDefaults.standard.set("sepia", forKey: AppTheme.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        snapshot(settings.view, name: "settings-sepia")
        let audio = try host(NASAudioView(trackName: "主题测试音频").appAppearance())
        try await Task.sleep(for: .milliseconds(150))
        snapshot(audio.view, name: "audio-sepia")
        XCTAssertEqual(audio.traitCollection.userInterfaceStyle, .light)
        UserDefaults.standard.set("dark", forKey: AppTheme.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        snapshot(audio.view, name: "audio-dark")
    }
    func testPaginationPreservesTextAndChapters() async throws {
        let text = "第一章 开始\n" + String(repeating: "中文阅读🙂测试，字体变化不会丢失段落。\n", count: 100) + "第二章 继续\n结尾。"
        let chapters = TextPaginator.detectChapters(in: text)
        let pages = await TextPaginator.paginate(text: text, font: .systemFont(ofSize: 17), lineSpacing: 8,
            containerSize: CGSize(width: 320, height: 700), insets: UIEdgeInsets(top: 60, left: 20, bottom: 80, right: 20), chapters: chapters)
        XCTAssertGreaterThan(pages.count, 1); XCTAssertEqual(pages.map(\.text).joined(), text); XCTAssertEqual(chapters.count, 2)
    }
    func testScrollingNovelRestoresAndSavesSameHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try ("第一章 起点\n" + String(repeating: "滚动小说阅读测试，保持稳定的阅读进度。\n", count: 200)).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try context()
        let history = ReadingHistory(title: "滚动小说", filePath: url.path, fileType: .txt, progress: 0.5)
        context.insert(history); try context.save()
        UserDefaults.standard.set("scroll", forKey: NovelReadingMode.storageKey)
        let controller = try host(TXTReaderView(fileURL: url, historyItem: history).modelContainer(context.container).appAppearance())
        var scroll: UIScrollView?
        for _ in 0..<120 {
            scroll = descendant(controller.view, as: UIScrollView.self)
            if let scroll, scroll.contentSize.height > scroll.bounds.height * 2, scroll.contentOffset.y > 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let reader = try XCTUnwrap(scroll)
        XCTAssertGreaterThan(reader.contentSize.height, reader.bounds.height * 2)
        XCTAssertGreaterThan(reader.contentOffset.y, 1)
        reader.setContentOffset(CGPoint(x: 0, y: reader.bounds.height * 2), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        snapshot(controller.view, name: "novel-scroll")
        UserDefaults.standard.set("paged", forKey: NovelReadingMode.storageKey)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(descendant(controller.view, as: UIScrollView.self))
        UserDefaults.standard.set("scroll", forKey: NovelReadingMode.storageKey)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try XCTUnwrap(descendant(controller.view, as: UIScrollView.self)).contentOffset.y, 1)
        UserDefaults.standard.set(22, forKey: "readerFontSize")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(try XCTUnwrap(descendant(controller.view, as: UIScrollView.self)).contentOffset.y, 1)
        controller.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReadingHistory>()), 1)
        XCTAssertGreaterThan(history.progress, 0); XCTAssertLessThan(history.progress, 0.5); XCTAssertEqual(history.filePath, url.path)
    }
    func testEPUBThemeUpdatePreservesLoadedDocumentAndScroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chapter.html")
        let html = "<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>章节</title></head><body>" + String(repeating: "<p>这是用于验证主题切换和阅读位置的段落。</p>", count: 100) + "<script>document.title='内容脚本已运行';</script></body></html>"
        try html.write(to: url, atomically: true, encoding: .utf8)
        let controller = try host(ThemeEPUBHost(chapter: EPUBChapter(title: "章节", htmlURL: url)).appAppearance())
        for _ in 0..<120 {
            if descendant(controller.view, as: WKWebView.self) != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = try XCTUnwrap(descendant(controller.view, as: WKWebView.self))
        for _ in 0..<120 {
            if !web.isLoading, web.scrollView.contentSize.height > 1000 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let originalTitle = try await web.callAsyncJavaScript("return document.title;", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(originalTitle as? String, "章节")
        _ = try await web.callAsyncJavaScript("document.body.dataset.marker='retained'; window.scrollTo(0, 400);", arguments: [:], in: nil, contentWorld: .defaultClient)
        UserDefaults.standard.set("dark", forKey: AppTheme.storageKey)
        try await Task.sleep(for: .milliseconds(200))
        let state = try await web.callAsyncJavaScript("return [document.body.dataset.marker, getComputedStyle(document.body).backgroundColor, window.scrollY];", arguments: [:], in: nil, contentWorld: .defaultClient)
        let values = try XCTUnwrap(state as? [Any])
        XCTAssertEqual(values[0] as? String, "retained")
        XCTAssertEqual(values[1] as? String, "rgb(28, 28, 30)")
        XCTAssertGreaterThan(values[2] as? Double ?? 0, 300)
        snapshot(controller.view, name: "epub-dark")
    }
    func testLongLoadingTitleWithinNarrowViewport() async throws {
        let title = String(repeating: "这是用于验证换行的很长的视频标题，", count: 18)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 300))
        let cover = renderer.image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 300)) }
        var overflow = false
        let controller = try host(VideoLoadingView(title: title, duration: "12:34", image: cover,
            onOverflow: { overflow = $0 }, onViewPage: {}, onCancel: {}), size: CGSize(width: 320, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(descendant(controller.view, as: UIScrollView.self))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, 321)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertTrue(overflow)
        snapshot(controller.view, name: "loading-long-title")
        let largeText = try host(VideoLoadingView(title: title, duration: "", image: nil, onViewPage: {}, onCancel: {})
            .environment(\.dynamicTypeSize, .accessibility3), size: CGSize(width: 320, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(try XCTUnwrap(descendant(largeText.view, as: UIScrollView.self)).contentSize.width, 321)
        snapshot(largeText.view, name: "loading-accessibility-text")
    }
}

private struct ThemeEPUBHost: View {
    let chapter: EPUBChapter
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    var body: some View { EPUBWebView(chapter: chapter, fontSize: 17, theme: theme, onTap: {}) }
}
