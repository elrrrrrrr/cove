import XCTest
import WebKit
import SwiftUI
import SwiftData
import AVKit
@testable import Cove

@MainActor final class VideoHandoffTests: XCTestCase {
    private func installRule(url: URL) -> [SiteDefinition] {
        let previous = SiteParserRegistry.definitions
        var value = SiteDefinition.starter(name: "延迟视频", url: url)
        value.id = "test.video.handoff"
        value.rules = [.init(id: "video", role: "video", extract: .init(script: """
        const main = document.querySelector('[data-role="content"]');
        const url = main?.getAttribute('data-source');
        return url ? {url: new URL(url, document.baseURI).href, type:'mp4'} : null;
        """))]
        SiteParserRegistry.replaceDefinitions([value])
        return previous
    }
    private func wait(_ condition: () -> Bool, seconds: Double = 15) async throws {
        for _ in 0..<Int(seconds * 50) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("视频状态未在预期时间内更新")
        throw URLError(.timedOut)
    }
    private func fixture(_ html: String) throws -> ArticleFixtureServer {
        try ArticleFixtureServer(routes: ["/": ("text/html; charset=utf-8", Data(html.utf8))])
    }
    func testVideoDetailKeepsOneWebPageThenActuallyPlaysASixSecondNativeClip() async throws {
        let movieURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-body", withExtension: "mp4", subdirectory: "Video"))
        let movie = try Data(contentsOf: movieURL)
        let html = Data("""
        <html><head><meta charset="utf-8"></head><body style="background:#172b4d;color:white">
        <h1>合成网页播放器</h1><p>正文准备中；模拟六秒等待</p>
        <video data-role="content"></video><script>
        window.documentToken='keep-this-document';
        setTimeout(()=>document.querySelector('video').setAttribute('data-source','/body.mp4'),8000);
        </script></body></html>
        """.utf8)
        let server = try ArticleFixtureServer(routes: ["/": ("text/html; charset=utf-8", html), "/body.mp4": ("video/mp4", movie)], rangeRequests: true)
        let url = try XCTUnwrap(URL(string: server.url + "/"))
        let previous = installRule(url: url)
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let model = try ModelContainer(for: FavoriteVideo.self, ReadingHistory.self, BookmarkSite.self, NASConfig.self, OfflineItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("缺少 UI 测试场景") }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: NavigationStack {
            VideoDetailView(item: ParsedItem(title: "原生视频接管演示", pageURL: url, thumbnail: nil, duration: "", extra: ""), definitionID: "test.video.handoff")
        }.modelContainer(model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func webViews(_ view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        func nativePlayers(_ view: UIViewController) -> [AVPlayerViewController] {
            (view as? AVPlayerViewController).map { [$0] } ?? view.children.flatMap(nativePlayers)
        }
        try await wait { webViews(host.view).first?.isHidden == false }
        let page = try XCTUnwrap(webViews(host.view).first)
        XCTAssertEqual(webViews(host.view).count, 1)
        let before = try await WebScript.string("window.documentToken", in: page)
        XCTAssertEqual(before, "keep-this-document")
        let webShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        webShot.name = "video-live-page-before-handoff"; webShot.lifetime = .keepAlways; add(webShot)
        try await wait { nativePlayers(host).first?.player?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(nativePlayers(host).first?.player)
        try await wait { player.currentTime().seconds > 0.1 && player.rate > 0 }
        let duration = try await player.currentItem!.asset.load(.duration)
        XCTAssertEqual(duration.seconds, 6, accuracy: 0.1)
        let after = try await WebScript.string("window.documentToken", in: page)
        XCTAssertEqual(after, before, "原生接管不重建网页")
        let nativeShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        nativeShot.name = "video-native-playing-after-handoff"; nativeShot.lifetime = .keepAlways; add(nativeShot)
    }

    func testSixSecondGateAutomaticallyHandsOffWithoutReloadingTheDocument() async throws {
        let server = try fixture("""
        <html><head><meta charset="utf-8"></head><body>
        <video data-role="advertisement" data-source="/ads/intro.mp4"></video>
        <video data-role="content"></video><script>
        window.documentToken = 'same-loaded-page'; window.pauseCount = 0;
        HTMLMediaElement.prototype.pause = function(){window.pauseCount++};
        setTimeout(()=>document.querySelector('[data-role="content"]').setAttribute('data-source','/body.mp4'),6500);
        </script></body></html>
        """)
        let url = try XCTUnwrap(URL(string: server.url + "/"))
        let previous = installRule(url: url)
        let extractor = VideoURLExtractor()
        defer { extractor.cancel(); SiteParserRegistry.replaceDefinitions(previous) }
        extractor.load(url: url, definitionID: "test.video.handoff")
        try await wait { extractor.state == .notFound }
        let page = extractor.webView
        let observation = Task { await extractor.observePreparedSource() }
        defer { observation.cancel() }
        try await wait { if case .found = extractor.state { return true }; return false }
        await observation.value
        guard case .found(let result) = extractor.state else { return XCTFail("正文就绪后未自动接管") }
        XCTAssertEqual(result.streamURL, url.appendingPathComponent("body.mp4"))
        XCTAssertTrue(extractor.webView === page)
        let token = try await WebScript.string("window.documentToken", in: page)
        XCTAssertEqual(token, "same-loaded-page")
        let pauses = try await WebScript.evaluate("window.pauseCount", in: page) as? Int
        XCTAssertGreaterThanOrEqual(pauses ?? 0, 2, "原生接管前停止网页音视频，避免重复播放")
        _ = try await WebScript.evaluate("(function(){document.querySelector('[data-role=content]').removeAttribute('data-source');return 'cleared';})()", in: page)
        extractor.webView(page, didFinish: nil)
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(extractor.state, .found(result), "迟到的页面完成回调不能把原生播放退回解析失败")
    }
    func testCancellingObservationKeepsThePageAndAllowsResumingAfterInteraction() async throws {
        let server = try fixture("<video data-role='content'></video>")
        let url = try XCTUnwrap(URL(string: server.url + "/"))
        let previous = installRule(url: url)
        let extractor = VideoURLExtractor()
        defer { extractor.cancel(); SiteParserRegistry.replaceDefinitions(previous) }
        extractor.load(url: url, definitionID: "test.video.handoff")
        try await wait { extractor.state == .notFound }
        let task = Task { await extractor.observePreparedSource() }
        await Task.yield(); task.cancel(); await task.value
        _ = try await WebScript.evaluate("(function(){document.querySelector('video').setAttribute('data-source','/short.mp4'); return 'ready';})()", in: extractor.webView)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(extractor.state, .notFound)
        let observation = Task { await extractor.observePreparedSource() }
        defer { observation.cancel() }
        try await wait { if case .found = extractor.state { return true }; return false }
        await observation.value
        guard case .found(let result) = extractor.state else { return XCTFail("恢复观察后未提取正文") }
        XCTAssertEqual(result.streamURL, url.appendingPathComponent("short.mp4"))
    }
    func testClosingAnExtractorStopsObservationBeforeAnotherPageCanPublish() async throws {
        let server = try fixture("<video data-role='content'></video>")
        let url = try XCTUnwrap(URL(string: server.url + "/"))
        let previous = installRule(url: url)
        let extractor = VideoURLExtractor()
        defer { extractor.cancel(); SiteParserRegistry.replaceDefinitions(previous) }
        extractor.load(url: url, definitionID: "test.video.handoff")
        try await wait { extractor.state == .notFound }
        let task = Task { await extractor.observePreparedSource() }
        await Task.yield(); extractor.cancel()
        _ = try await WebScript.evaluate("(function(){document.querySelector('video').setAttribute('data-source','/stale.mp4'); return 'ready';})()", in: extractor.webView)
        await task.value
        XCTAssertEqual(extractor.state, .notFound)
    }
}
