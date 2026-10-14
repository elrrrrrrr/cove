import XCTest
import SwiftUI
import WebKit
@testable import Cove

@MainActor final class ParsingWebViewTests: XCTestCase {
    private var window: UIWindow?
    override func tearDown() async throws {
        await MainActor.run { window?.rootViewController = nil; window?.isHidden = true; window = nil }
        try await super.tearDown()
    }
    private func host(_ view: UIView) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let controller = UIViewController(); window.rootViewController = controller
        if view.frame.isEmpty { view.frame = window.bounds }
        controller.view.addSubview(view); window.makeKeyAndVisible(); self.window = window
    }
    private func ready(_ web: WKWebView) async throws {
        for _ in 0..<160 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Fixture did not finish loading")
    }

    func testMovingLiveViewKeepsDocumentDelegateAndRestoresHiddenHost() async throws {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        let delegate = NavigationCounter(); web.navigationDelegate = delegate
        let hidden = ParsingWebViewContainer(webView: web)
        hidden.frame = CGRect(x: 0, y: 0, width: 1, height: 1); try host(hidden)
        hidden.layoutSubviews()
        web.loadHTMLString("<html><head><title>解析现场</title></head><body><script>window.inspectionMarker='same-page';</script><p>原始页面内容</p></body></html>", baseURL: URL(string: "https://media.example/"))
        try await ready(web)
        for _ in 0..<80 {
            if delegate.finishes > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finishes = delegate.finishes
        let visible = ParsingWebViewContainer(webView: web)
        window?.rootViewController?.view.addSubview(visible)
        visible.frame = CGRect(x: 0, y: 0, width: 320, height: 500); visible.layoutSubviews()
        hidden.layoutSubviews()
        XCTAssertEqual(web.bounds.size, CGSize(width: 320, height: 500), "Hidden host must not resize the inspected page")
        XCTAssertTrue(web.navigationDelegate === delegate)
        let visibleMarker = try await web.evaluateJavaScript("window.inspectionMarker") as? String
        XCTAssertEqual(visibleMarker, "same-page")
        visible.restore()
        XCTAssertTrue(web.superview === hidden)
        hidden.layoutSubviews()
        XCTAssertEqual(web.bounds.size, CGSize(width: 1, height: 1))
        let restoredMarker = try await web.evaluateJavaScript("window.inspectionMarker") as? String
        XCTAssertEqual(restoredMarker, "same-page")
        XCTAssertEqual(delegate.finishes, finishes, "Inspection must not cause another navigation")
    }

    func testMetadataTracksPageChangesWithoutTakingOverNavigationDelegate() async throws {
        let web = WKWebView(), delegate = NavigationCounter()
        web.navigationDelegate = delegate; try host(ParsingWebViewContainer(webView: web))
        var info: ParsingWebPageInfo? = ParsingWebPageInfo(webView: web)
        weak var weakInfo = info
        web.loadHTMLString("<html><head><title>等待验证</title></head><body>页面</body></html>", baseURL: URL(string: "https://media.example/"))
        try await ready(web)
        _ = try await web.evaluateJavaScript("document.title='验证已完成'")
        for _ in 0..<40 {
            if info?.title == "验证已完成" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(info?.title, "验证已完成")
        XCTAssertEqual(info?.loading, false); XCTAssertTrue(web.navigationDelegate === delegate)
        info = nil
        XCTAssertNil(weakInfo, "Metadata observations must not retain their owner")
    }

    func testOriginalRequestsRetainConfiguredHeaders() throws {
        let url = URL(string: "http://127.0.0.1:1/inspect")!
        var definition = SiteDefinition.starter(name: "诊断夹具", url: url)
        definition.rules[0].load = .init(mode: "webView", headers: ["X-Inspection": "catalog"])
        definition.rules.append(.init(id: "detail", role: "video", load: .init(mode: "webView", headers: ["X-Inspection": "video"]), extract: .init(script: "return null;")))
        let saved = SiteParserRegistry.definitions; defer { SiteParserRegistry.replaceDefinitions(saved) }
        SiteParserRegistry.replaceDefinitions([definition])
        let loader = PageLoader()
        loader.load(url: url, parser: SiteParserRegistry.parser(definition: definition, rule: definition.rules[0]))
        XCTAssertEqual(loader.originalPageRequest?.url, url)
        XCTAssertEqual(loader.originalPageRequest?.value(forHTTPHeaderField: "X-Inspection"), "catalog")
        let extractor = VideoURLExtractor()
        extractor.load(url: url, definitionID: definition.id)
        XCTAssertEqual(extractor.originalPageRequest?.value(forHTTPHeaderField: "X-Inspection"), "video")
        extractor.cancel(); loader.webView.stopLoading()
    }
}

@MainActor private final class NavigationCounter: NSObject, WKNavigationDelegate {
    var finishes = 0
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishes += 1 }
    }
}
