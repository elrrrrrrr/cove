import XCTest
import SwiftUI
@testable import Cove

@MainActor final class BrowserLayoutTests: XCTestCase {
    private func entries() -> [NASFileEntry] {
        (0..<30).map { index in
            let name = index < 2 ? "资源文件夹 \(index)" : ["视频 \(index).mp4", "小说 \(index).txt", "漫画 \(index).cbz", "音乐 \(index).opus", "图片 \(index).jpg"][index % 5]
            return NASFileEntry(name: name, path: "/媒体/" + name, isDirectory: index < 2, size: 1024 * 1024, modifiedAt: .distantPast)
        }
    }
    func testPreferencesAreScopedBySourceAndDirectory() {
        let keys = [BrowserLayout.preferenceKey(source: "nas:a", location: "/媒体"),
                    BrowserLayout.preferenceKey(source: "nas:b", location: "/媒体"),
                    BrowserLayout.preferenceKey(source: "nas:a", location: "/图书"),
                    BrowserLayout.preferenceKey(source: "web", location: "https://media.example/")]
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertEqual(keys[0], BrowserLayout.preferenceKey(source: "nas:a", location: "/媒体"))
        XCTAssertFalse(keys[0].contains("媒体"))
        XCTAssertNotEqual(BrowserLayout.preferenceKey(source: "a:b", location: "c"), BrowserLayout.preferenceKey(source: "a", location: "b:c"))
        XCTAssertNil(BrowserLayout(rawValue: "grid"))
    }
    func testDirectoryOpeningStaysIndependentOfLayoutAndDownloads() {
        let items = entries()
        var directories: [String] = [], files: [String] = [], downloads = 0
        for layout in BrowserLayout.allCases {
            let content = NASDirectoryContent(entries: items, layout: layout, connection: nil, isDownloading: true,
                readPathSet: [], totalCount: items.count, onOpenDirectory: { directories.append($0) },
                onOpen: { files.append($0.path) }, onDownload: { _ in downloads += 1 }, onLoadMore: {})
            content.open(items[0]); content.open(items[2])
        }
        XCTAssertEqual(directories.count, 3); XCTAssertTrue(files.isEmpty); XCTAssertEqual(downloads, 0)
        for layout in BrowserLayout.allCases {
            NASDirectoryContent(entries: items, layout: layout, connection: nil, isDownloading: false,
                readPathSet: [], totalCount: items.count, onOpenDirectory: { _ in },
                onOpen: { files.append($0.path) }, onDownload: { _ in downloads += 1 }, onLoadMore: {}).open(items[2])
        }
        XCTAssertEqual(files, Array(repeating: items[2].path, count: 3)); XCTAssertEqual(downloads, 0)
    }
    func testNativeDirectorySwitchesAndRestoresThreeLayouts() async throws {
        let key = BrowserLayout.preferenceKey(source: "test:" + UUID().uuidString, location: "/")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let items = entries()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        let controller = UIHostingController(rootView: LayoutHarness(key: key, entries: items).appAppearance())
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for layout in BrowserLayout.allCases {
            UserDefaults.standard.set(layout.rawValue, forKey: key)
            try await Task.sleep(for: .milliseconds(200))
            let scroll = try XCTUnwrap(findScroll(controller.view))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
            let image = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "nas-" + layout.rawValue; attachment.lifetime = .keepAlways; add(attachment)
        }
        controller.rootView = LayoutHarness(key: key, entries: items).appAppearance()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "portrait")
    }
    func testBentoGroupsCoverEachResourceOnceIncludingPartialRows() {
        for count in 0...25 {
            for slots in [BentoGrouper.group2Col(count: count), BentoGrouper.group3Col(count: count)] {
                let indices = slots.flatMap { slot -> [Int] in
                    switch slot.kind {
                    case .fullWidth(let index): [index]
                    case .smallRow(let indices): indices
                    case .largeLeftSmallRight(let large, let top, let bottom): [large, top, bottom]
                    case .smallLeftLargeRight(let top, let bottom, let large): [top, bottom, large]
                    }
                }
                XCTAssertEqual(indices, Array(0..<count))
            }
        }
    }
    private func findScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
}

private struct LayoutHarness: View {
    @AppStorage private var saved: String
    let entries: [NASFileEntry]
    init(key: String, entries: [NASFileEntry]) {
        _saved = AppStorage(wrappedValue: "", key); self.entries = entries
    }
    var body: some View {
        let selection = Binding(get: { BrowserLayout(rawValue: saved) ?? .list }, set: { saved = $0.rawValue })
        NavigationStack {
            NASDirectoryContent(entries: entries, layout: selection.wrappedValue, connection: nil, isDownloading: false,
                readPathSet: [entries[2].path], totalCount: entries.count,
                onOpenDirectory: { _ in }, onOpen: { _ in }, onDownload: { _ in }, onLoadMore: {})
                .navigationTitle("资源目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { BrowserLayoutMenu(layout: selection) } }
        }
    }
}
