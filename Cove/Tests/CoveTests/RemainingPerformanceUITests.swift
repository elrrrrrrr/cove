import XCTest
import SwiftUI
import SwiftData
@testable import Cove

@MainActor final class RemainingPerformanceUITests: XCTestCase {
    private var windows: [UIWindow] = []
    private var containers: [ModelContainer] = []
    override func tearDown() async throws {
        for window in windows { window.rootViewController = nil; window.isHidden = true }
        windows.removeAll(); containers.removeAll(); try await super.tearDown()
    }
    private func host<V: View>(_ content: V) throws -> UIView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 620)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(rootView: content); controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller; window.makeKeyAndVisible(); windows.append(window)
        return controller.view
    }
    private func snapshot(_ view: UIView, name: String) -> UIImage {
        view.layoutIfNeeded()
        let picture = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: picture); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return picture
    }
    func testAllSkeletonLayoutsRenderAndRespectReducedMotion() async throws {
        for (name, view) in [("Bento", AnyView(BentoSkeletonGrid(columns: 2))),
                             ("竖版", AnyView(PortraitSkeletonGrid(columns: 3))),
                             ("列表", AnyView(ListSkeletonView()))] {
            let hosted = try host(view)
            try await Task.sleep(for: .milliseconds(180))
            let first = snapshot(hosted, name: "skeleton-" + name)
            XCTAssertGreaterThan(try grayPixels(first), 1000, "骨架不能消失")
            try await Task.sleep(for: .milliseconds(200))
            let second = snapshot(hosted, name: "skeleton-static-" + name)
            if UIAccessibility.isReduceMotionEnabled {
                XCTAssertEqual(first.pngData(), second.pngData(), "减弱动态效果时应保持静态")
            }
        }
    }
    func testRapidDownloadCompletionsPersistExactlyOnceAndHomeSectionsRemain() async throws {
        let container = try ModelContainer(for: ReadingHistory.self, BookmarkSite.self, FavoriteVideo.self, OfflineItem.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container); let context = container.mainContext
        let site = BookmarkSite(name: "快速访问示例", urlString: "https://media.example/", category: .video)
        context.insert(site)
        let record = ReadingHistory(title: "继续阅读示例", url: "https://media.example/read", progress: 0.3); context.insert(record); try context.save()
        let manager = DownloadManager(), source = FastOfflineSource(); manager.configureSMB(client: source)
        let view = try host(ContentView(downloadManager: manager).modelContainer(container).appAppearance())
        manager.add(title: "离线小说一", sourceURL: "/first.txt", fileType: .txt, isNAS: true)
        manager.add(title: "离线小说二", sourceURL: "/second.txt", fileType: .txt, isNAS: true)
        for _ in 0..<160 { if try context.fetchCount(FetchDescriptor<OfflineItem>()) == 2 { break }; try await Task.sleep(for: .milliseconds(15)) }
        let records = try context.fetch(FetchDescriptor<OfflineItem>()); XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.title)), ["离线小说一", "离线小说二"])
        XCTAssertTrue(manager.pendingPersist.isEmpty); XCTAssertTrue(manager.downloads.isEmpty)
        for item in records { XCTAssertTrue(item.localPath.hasPrefix("Offline/nas/")); XCTAssertNotNil(OfflineFiles.shared.url(for: item.localPath)) }
        _ = snapshot(view, name: "home-index-and-offline-completion")
        try await Task.sleep(for: .milliseconds(100))
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollView(in: view))
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        _ = snapshot(view, name: "home-offline-rows")
        await manager.clear()
        for item in records { OfflineFiles.shared.deleteFile(path: item.localPath) }
    }
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
        return nil
    }
    private func grayPixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage); var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let pixels = buffer.bindMemory(to: UInt8.self); var count = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 200 && r < 250 && abs(r - g) < 4 && abs(g - b) < 12 { count += 1 }
            }
            return count
        }
    }
}
private actor FastOfflineSource: OfflineDownloadSource {
    nonisolated let cacheIdentity = "offline-ui-fixture"
    func download(remotePath: String, to: URL, maxBytes: Int64, progress: @Sendable @escaping (Double) -> Void) async throws {
        try Data("第一章\n离线小说内容".utf8).write(to: to); progress(1)
    }
}
