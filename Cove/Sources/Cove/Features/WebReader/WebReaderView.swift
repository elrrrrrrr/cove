import SwiftUI
import WebKit
import SwiftData

/// Full-screen web reader with ad blocking, immersive mode, and reading progress tracking.
struct WebReaderView: View {
    let url: URL
    var historyItem: ReadingHistory? = nil   // pass in to resume & update progress
    /// Optional close handler — when set, the back button calls this instead of dismiss().
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var webCoordinator = WebCoordinator()
    @State private var showBars       = true
    @State private var canGoBack      = false
    @State private var canGoForward   = false
    @State private var isLoading      = false
    @State private var pageTitle      = ""
    @State private var scrollProgress : Double = 0
    @State private var showSavedAlert = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebViewRepresentable(
                url: url,
                webCoordinator: webCoordinator,
                onTitleChange:   { pageTitle = $0 },
                onNavChange:     { canGoBack = $0; canGoForward = $1 },
                onLoading:       { isLoading = $0 },
                onProgressChange: { scrollProgress = $0 },
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                }
            )
            .ignoresSafeArea()

            if showBars {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .alert("已保存到稍后再看", isPresented: $showSavedAlert) {
            Button("好") {}
        }
        .task {
            await webCoordinator.loadBlocker()
        }
        .onDisappear {
            saveProgress()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            if isLoading { ProgressView().scaleEffect(0.8) }
            Spacer()
            Text(pageTitle.isEmpty ? (url.host() ?? "") : pageTitle)
                .font(.headline).lineLimit(1)
            Spacer()
            Button { saveForLater() } label: {
                Image(systemName: "bookmark")
            }
            Menu {
                Button("刷新")      { webCoordinator.reload() }
                Button("复制链接")  { UIPasteboard.general.url = webCoordinator.currentURL }
                Button("在 Safari 中打开") {
                    if let u = webCoordinator.currentURL { UIApplication.shared.open(u) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ProgressView(value: scrollProgress).tint(.accentColor)
            HStack(spacing: 32) {
                Button { webCoordinator.goBack() } label: {
                    Image(systemName: "chevron.left").imageScale(.large)
                }
                .disabled(!canGoBack)
                Button { webCoordinator.goForward() } label: {
                    Image(systemName: "chevron.right").imageScale(.large)
                }
                .disabled(!canGoForward)
                Spacer()
                Button { webCoordinator.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                ShareLink(item: webCoordinator.currentURL ?? url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func saveForLater() {
        let currentURL = webCoordinator.currentURL ?? url
        let detected = FileTypeDetector.detect(from: currentURL)
        let title = pageTitle.isEmpty ? currentURL.lastPathComponent : pageTitle

        if detected != .unknown {
            // Downloadable file — enqueue real download
            DownloadManager.shared.add(
                title: title,
                sourceURL: currentURL.absoluteString,
                fileType: detected
            )
        } else {
            // Web page — save metadata bookmark
            let item = OfflineItem(
                title: pageTitle.isEmpty ? url.absoluteString : pageTitle,
                sourceURL: currentURL.absoluteString,
                localPath: "",
                fileType: .web
            )
            context.insert(item)
        }
        showSavedAlert = true
    }

    private func saveProgress() {
        let currentURL = webCoordinator.currentURL ?? url
        if let existing = historyItem {
            existing.progress   = min(1, max(0, scrollProgress))
            existing.lastReadAt = Date()
        } else {
            let entry = ReadingHistory(
                title: pageTitle.isEmpty ? currentURL.absoluteString : pageTitle,
                url: currentURL.absoluteString,
                fileType: .web,
                progress: min(1, max(0, scrollProgress))
            )
            context.insert(entry)
        }
    }
}

// MARK: - UIViewRepresentable bridge

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let webCoordinator: WebCoordinator

    var onTitleChange:   (String) -> Void   = { _ in }
    var onNavChange:     (Bool, Bool) -> Void = { _, _ in }
    var onLoading:       (Bool) -> Void     = { _ in }
    var onProgressChange: (Double) -> Void  = { _ in }
    var onTap:           () -> Void         = {}

    func makeUIView(context: Context) -> WKWebView {
        let wv = webCoordinator.webView
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate         = context.coordinator

        // Register scroll progress message handler (weakly via coordinator)
        wv.configuration.userContentController.add(
            context.coordinator,
            name: "scrollProgress"
        )

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        wv.addGestureRecognizer(tap)

        context.coordinator.onTitleChange    = onTitleChange
        context.coordinator.onNavChange      = onNavChange
        context.coordinator.onLoading        = onLoading
        context.coordinator.onProgressChange = onProgressChange
        context.coordinator.onTap            = onTap

        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                             UIGestureRecognizerDelegate, WKScriptMessageHandler {

        var onTitleChange   : (String) -> Void    = { _ in }
        var onNavChange     : (Bool, Bool) -> Void = { _, _ in }
        var onLoading       : (Bool) -> Void       = { _ in }
        var onProgressChange: (Double) -> Void     = { _ in }
        var onTap           : () -> Void           = {}

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onTitleChange(webView.title ?? "")
            onNavChange(webView.canGoBack, webView.canGoForward)
            onLoading(false)

            let js = """
            (function() {
                if (window.__easyReaderScrollBound) return;
                window.__easyReaderScrollBound = true;
                function prog() {
                    var h = document.documentElement;
                    var total = h.scrollHeight - h.clientHeight;
                    return total > 0 ? h.scrollTop / total : 0;
                }
                window.addEventListener('scroll', function() {
                    window.webkit.messageHandlers.scrollProgress.postMessage(prog());
                }, { passive: true });
            })();
            """
            webView.evaluateJavaScript(js)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoading(true)
        }


        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoading(false)
        }

        // MARK: Script message handler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "scrollProgress", let value = message.body as? Double {
                onProgressChange(value)
            }
        }

        // MARK: Gestures

        @objc func handleTap() { onTap() }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

// MARK: - WebCoordinator (owns the WKWebView)

@Observable
@MainActor
final class WebCoordinator {

    let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore              = SiteWebSession.dataStore
        config.allowsInlineMediaPlayback     = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }()

    var currentURL: URL? { webView.url }

    func loadBlocker() async {
        do {
            let list = try await ContentBlocker.shared.ruleList()
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.configuration.userContentController.add(list)
        } catch {
            print("Content blocker failed: \(error)")
        }
    }

    func reload()     { webView.reload() }
    func goBack()     { webView.goBack() }
    func goForward()  { webView.goForward() }
}
