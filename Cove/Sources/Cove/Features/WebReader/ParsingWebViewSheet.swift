import SwiftUI
import WebKit

/// Moves the live page without replacing its delegate, reloading it, or stopping extraction.
final class ParsingWebViewContainer: UIView {
    let webView: WKWebView
    private weak var previousParent: UIView?
    private let previousFrame: CGRect
    private let previousAccessibilityHidden: Bool
    private let previousHidden: Bool

    init(webView: WKWebView, accessibilityHidden: Bool = false) {
        self.webView = webView
        previousParent = webView.superview
        previousFrame = webView.frame
        previousAccessibilityHidden = webView.accessibilityElementsHidden
        previousHidden = webView.isHidden
        super.init(frame: .zero)
        accessibilityElementsHidden = accessibilityHidden
        webView.accessibilityElementsHidden = accessibilityHidden
        webView.isHidden = accessibilityHidden
        webView.removeFromSuperview()
        addSubview(webView)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        if webView.superview === self { webView.frame = bounds }
    }
    func restore() {
        guard webView.superview === self else { return }
        webView.removeFromSuperview()
        webView.accessibilityElementsHidden = previousAccessibilityHidden
        webView.isHidden = previousHidden
        if let previousParent {
            previousParent.addSubview(webView)
            webView.frame = previousFrame
            previousParent.setNeedsLayout()
        }
    }
}

struct ParsingWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> ParsingWebViewContainer { ParsingWebViewContainer(webView: webView) }
    func updateUIView(_ uiView: ParsingWebViewContainer, context: Context) {}
    static func dismantleUIView(_ uiView: ParsingWebViewContainer, coordinator: ()) { uiView.restore() }
}

@Observable @MainActor final class ParsingWebPageInfo {
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var loading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView) {
        refresh(webView)
        let update: @Sendable (WKWebView) -> Void = { [weak self] view in
            Task { @MainActor in self?.refresh(view) }
        }
        observations = [
            webView.observe(\.url, options: [.new]) { view, _ in update(view) },
            webView.observe(\.title, options: [.new]) { view, _ in update(view) },
            webView.observe(\.isLoading, options: [.new]) { view, _ in update(view) },
            webView.observe(\.estimatedProgress, options: [.new]) { view, _ in update(view) },
            webView.observe(\.canGoBack, options: [.new]) { view, _ in update(view) },
            webView.observe(\.canGoForward, options: [.new]) { view, _ in update(view) }
        ]
    }
    private func refresh(_ view: WKWebView) {
        url = view.url; title = view.title ?? ""
        loading = view.isLoading; progress = view.estimatedProgress
        canGoBack = view.canGoBack; canGoForward = view.canGoForward
    }
}

struct ParsingWebViewSheet: View {
    let webView: WKWebView
    let request: URLRequest
    let status: String
    @State private var fullPage: WKWebView?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ParsingWebPageContent(webView: fullPage ?? webView, fallbackURL: request.url,
                                  status: fullPage == nil ? status : "完整原网页", isFullPage: fullPage != nil)
                .id(ObjectIdentifier(fullPage ?? webView))
                .navigationTitle("原始网页")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回解析") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("查看解析中的页面", systemImage: "doc.text.magnifyingglass") { fullPage = nil }
                            Button("重新打开完整原网页", systemImage: "safari") { openFullPage() }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("网页查看选项")
                    }
                }
        }
        .toolbar(.visible, for: .navigationBar)
        .statusBarHidden(false)
        .presentationDragIndicator(.visible)
    }
    private func openFullPage() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        configuration.allowsInlineMediaPlayback = true
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.customUserAgent = webView.customUserAgent
        page.allowsBackForwardNavigationGestures = true
        page.load(request)
        fullPage = page
    }
}

private struct ParsingWebPageContent: View {
    let webView: WKWebView
    let fallbackURL: URL?
    let status: String
    let isFullPage: Bool
    @State private var info: ParsingWebPageInfo
    init(webView: WKWebView, fallbackURL: URL?, status: String, isFullPage: Bool) {
        self.webView = webView; self.fallbackURL = fallbackURL; self.status = status
        self.isFullPage = isFullPage
        _info = State(initialValue: ParsingWebPageInfo(webView: webView))
    }
    private var address: URL? {
        if let url = info.url, ["http", "https"].contains(url.scheme ?? "") { return url }
        return fallbackURL
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !info.title.isEmpty { Text(info.title).font(.subheadline).lineLimit(2) }
                Text(address?.absoluteString ?? "尚未加载网页").font(.caption.monospaced())
                    .lineLimit(3).textSelection(.enabled).accessibilityIdentifier("parsing-web-address")
                Text(status).font(.caption).foregroundStyle(.secondary)
                if !isFullPage {
                    Text("当前展示解析中的页面。若页面经过预处理，可从右上角重新打开完整原网页。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            if info.loading { ProgressView(value: info.progress).tint(.accentColor) }
            ParsingWebViewHost(webView: webView).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("parsing-live-webview")
        }
        .appSurface()
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("后退", systemImage: "chevron.left") { webView.goBack() }.disabled(!info.canGoBack)
                Button("前进", systemImage: "chevron.right") { webView.goForward() }.disabled(!info.canGoForward)
                Spacer()
                if let address {
                    Button("复制地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = address }
                    ShareLink(item: address)
                }
            }
        }
    }
}
