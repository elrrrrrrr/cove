import WebKit
import SwiftUI
import os

// MARK: - WebReader TLS policy

enum WebReaderTLS {
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        return false
    }
}

// MARK: - PageLoader

/// Owns a WKWebView, renders a URL, then runs a JS extractor and returns ParsedItems.
/// Supports SWR: shows cached items immediately, then refreshes in background.
/// Supports pagination: AJAX (fetch via JS) and webNavigation (WKWebView next-page link).
@Observable
@MainActor
final class PageLoader: NSObject {

    enum State {
        case idle, loading, extracting, done([ParsedItem]), failed(String)

        var isActive: Bool {
            if case .loading    = self { return true }
            if case .extracting = self { return true }
            return false
        }
    }

    var state         : State = .idle
    var isLoadingMore = false   // fetching next page
    var currentPage   : Int = 1
    var hasNextPage   : Bool = false  // AJAX mode: more pages available
    var nextPageURL   : URL? = nil    // webNavigation mode: next URL
    var paginationFailed = false      // last pagination attempt failed → show retry

    /// Debug log: records key events during the loading/extraction process.
    var parseLog      : [String] = []

    /// Can navigate to next page?
    var canLoadMore: Bool {
        guard !isLoadingMore else { return false }
        guard let p = parser else { return false }
        switch p.paginationMode {
        case .none:           return false
        case .ajax:           return hasNextPage
        case .webNavigation:  return nextPageURL != nil
        }
    }

    /// Can navigate to previous page?
    var canLoadPrevious: Bool {
        !isLoadingMore && currentPage > 1
    }

    var currentURL: URL?
    /// Cached resolved host from portal resolution — avoids re-fetching portal on category switch.
    private var resolvedHost: String?

    /// The URL the WebView actually settled on (may differ from currentURL after redirects/preNavigateJS).
    var resolvedBaseURL: URL? { _webView?.url ?? currentURL }

    /// Lazily-created WKWebView — avoids blocking the main thread during view init.
    private(set) var webView: WKWebView {
        get {
            if let wv = _webView { return wv }
            let wv = Self.createWebView()
            wv.navigationDelegate = self
            _webView = wv
            // Host in off-screen UIWindow for navigation delegate + JS execution
            let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            win.windowLevel = .init(rawValue: -1)
            win.isHidden = false
            win.rootViewController = UIViewController()
            win.rootViewController?.view.addSubview(wv)
            _backgroundWindow = win
            // Apply content blocker asynchronously
            Task { [weak wv] in
                if let list = try? await ContentBlocker.shared.ruleList() {
                    wv?.configuration.userContentController.add(list)
                }
            }
            return wv
        }
        set { _webView = newValue }
    }
    private var _webView: WKWebView?
    private var parser   : SiteParser?
    private var allItems : [ParsedItem] = []
    private var loadTimeoutTask: Task<Void, Never>?
    private var isExtracting = false
    private var _backgroundWindow: UIWindow?

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = mobileUserAgent
        return wv
    }

    override init() {
        super.init()
        // Lightweight — WKWebView created lazily on first load()
    }

    private static let logger = Logger(subsystem: "com.easyreader", category: "PageLoader")

    private func log(_ msg: String) {
        let ts = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        let truncated = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
        let line = "[\(ts)] \(truncated)"
        parseLog.append(line)
        Self.logger.info("\(msg)")
    }

    // MARK: - Load (SWR)

    /// Pre-populate state from a cached snapshot so the first render already shows content.
    /// Called from SiteGalleryView.init before the view appears.
    func preload(_ items: [ParsedItem]) {
        allItems = items
        state    = .done(items)
    }

    func load(url: URL, parser: SiteParser, forceRefresh: Bool = false) {
        if forceRefresh || self.parser?.portal != parser.portal { resolvedHost = nil }
        self.parser     = parser
        self.currentURL = url
        currentPage     = 1
        hasNextPage     = false
        nextPageURL     = nil
        isLoadingMore   = false
        paginationFailed = false
        parseLog        = []

        log("load: url=\(url.absoluteString)")
        log("load: parser=\(parser.hostPattern), needsJS=\(parser.needsJS), portal=\(parser.portalURL ?? "nil")")

        let hasCachedContent: Bool
        if case .done = state { hasCachedContent = true } else { hasCachedContent = false }

        if !hasCachedContent || forceRefresh {
            allItems = []
            state    = .loading
        }

        isExtracting = false
        usedFastLoad = false
        loadTimeoutTask?.cancel()

        // Portal domain resolution: always resolve when parser has a portalURL.
        // This handles stale bookmark domains (e.g. old mirrors that no longer work).
        // Once resolved, cache the host to skip re-fetching portal on category switch.
        if parser.portalURL != nil {
            if let cached = resolvedHost {
                // Reuse cached resolved host — just swap host and load
                var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                components?.host = cached
                let resolved = components?.url ?? url
                log("load: portal host cached → \(resolved.absoluteString)")
                currentURL = resolved
                if parser.needsJS { fallbackToWebView(url: resolved) }
                else { Task { await fetchAndLoad(url: resolved) } }
            } else {
                log("load: portal resolution triggered (urlHost=\(url.host() ?? "nil"))")
                Task { await resolvePortalAndLoad(url: url, parser: parser) }
            }
        } else if parser.needsJS {
            log("load: using WebView (needsJS=true)")
            fallbackToWebView(url: url)
        } else {
            log("load: using fast-load (URLSession)")
            Task { await fetchAndLoad(url: url) }
        }
    }

    /// URLSession fetch → strip resource tags → loadHTMLString.
    private var usedFastLoad = false

    private func fetchAndLoad(url: URL) async {
        log("fetchAndLoad: fetching \(url.absoluteString)")
        let warmup = Task { @MainActor in _ = self.webView }

        do {
            var request = URLRequest(url: url)
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            for (name, value) in parser?.requestHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log("fetchAndLoad: HTTP \(code) → fallback to WebView")
                fallbackToWebView(url: url)
                return
            }
            guard let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
                log("fetchAndLoad: encoding failed → fallback to WebView")
                fallbackToWebView(url: url)
                return
            }
            log("fetchAndLoad: got \(html.count) chars, stripping scripts")
            await warmup.value
            let transformed: String
            if let script = parser?.transformScript {
                transformed = try await webView.callAsyncJavaScript(script, arguments: ["html": html], in: nil, contentWorld: .page) as? String ?? html
            } else { transformed = html }
            let stripped = Self.stripResourceTags(transformed)
            log("fetchAndLoad: stripped to \(stripped.count) chars, loading HTML")
            usedFastLoad = true
            await warmup.value
            webView.loadHTMLString(stripped, baseURL: url)
            startLoadTimeout()
        } catch {
            log("fetchAndLoad: error \(error.localizedDescription) → fallback to WebView")
            fallbackToWebView(url: url)
        }
    }

    static func stripResourceTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script\b[^>]*>[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<script\b[^/]*/>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<link\b[^>]*>"#, with: "", options: .regularExpression)
    }

    private func resolvePortalAndLoad(url: URL, parser: SiteParser) async {
        log("resolvePortal: portal=\(parser.portalURL!), target=\(url.absoluteString)")
        let loadURL: URL
        if let resolved = await SitePortalResolver.fetch(config: parser.portal ?? SitePortal(url: parser.portalURL!), target: url) {
            log("resolvePortal: resolved → \(resolved.absoluteString)")
            resolvedHost = resolved.host()
            currentURL = resolved
            loadURL = resolved
        } else {
            log("resolvePortal: FAILED, using original URL")
            loadURL = url
        }
        if parser.needsJS {
            log("resolvePortal: loading via WebView (needsJS=true)")
            fallbackToWebView(url: loadURL)
        } else {
            log("resolvePortal: loading via fast-load")
            await fetchAndLoad(url: loadURL)
        }
    }

    /// Fallback: let WKWebView navigate normally (for JS-rendered sites or network errors).
    private func fallbackToWebView(url: URL) {
        usedFastLoad = false
        var request = URLRequest(url: url)
        for (name, value) in parser?.requestHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        webView.load(request)
        startLoadTimeout()
    }

    /// If didFinish hasn't fired within 15 seconds, try extracting from whatever is loaded.
    private func startLoadTimeout() {
        loadTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            // Still loading — force extraction attempt
            if case .loading = state {
                await extract()
            }
        }
    }

    func reload() {
        guard let url = currentURL, let parser else { return }
        load(url: url, parser: parser, forceRefresh: true)
    }

    /// Async reload suitable for SwiftUI .refreshable {}
    func reloadAsync() async {
        reload()
        while (state.isActive) {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    // MARK: - Pagination

    /// Load the next page.
    func loadMore() {
        guard !isLoadingMore, let p = parser else { return }
        let nextPage = currentPage + 1
        isLoadingMore = true
        paginationFailed = false
        switch p.paginationMode {
        case .none:
            isLoadingMore = false
        case .ajax(let js, let thumbnailJS):
            Task { await fetchAjaxPage(nextPage, js: js, thumbnailJS: thumbnailJS) }
        case .webNavigation:
            if let next = nextPageURL {
                webView.load(URLRequest(url: next))
            } else {
                // Construct URL for next page by reloading at page N
                goToPage(nextPage, parser: p)
            }
        }
    }

    /// Load the previous page.
    func loadPrevious() {
        guard !isLoadingMore, currentPage > 1, let p = parser else { return }
        let prevPage = currentPage - 1
        isLoadingMore = true
        switch p.paginationMode {
        case .ajax(let js, let thumbnailJS):
            Task { await fetchAjaxPage(prevPage, js: js, thumbnailJS: thumbnailJS) }
        default:
            goToPage(prevPage, parser: p)
        }
    }

    /// Jump directly to a specific page.
    func loadPage(_ page: Int) {
        guard let p = parser else { return }
        goToPage(page, parser: p)
    }

    /// Internal: navigate to an arbitrary page number.
    private func goToPage(_ page: Int, parser p: SiteParser) {
        switch p.paginationMode {
        case .none:
            break
        case .ajax(let js, let thumbnailJS):
            allItems      = []
            currentPage   = page
            hasNextPage   = false
            isLoadingMore = true
            state         = .loading
            Task { await fetchAjaxPage(page, js: js, thumbnailJS: thumbnailJS) }
        case .webNavigation:
            // Web-navigation sites: reload from scratch (URL reconstruction is site-specific)
            reload()
        }
    }

    // MARK: - AJAX page fetch

    private func fetchAjaxPage(_ page: Int, js: String, thumbnailJS: String? = nil) async {
        log("fetchAjaxPage: page=\(page), webViewURL=\(webView.url?.absoluteString ?? "nil")")
        do {
            let raw = try await runPageJS(js, page: page)

            guard let data = raw.data(using: .utf8) else {
                isLoadingMore = false; return
            }
            let decoded  = try JSONDecoder().decode([RawItem].self, from: data)
            let base     = webView.url ?? currentURL!
            let newItems = Array(decoded.compactMap { ParsedItem(from: $0, base: base) }.prefix(30))
            log("fetchAjaxPage: got \(newItems.count) items (raw=\(decoded.count))")
            if let first = newItems.first { log("fetchAjaxPage: first=\(first.pageURL.absoluteString)") }
            if let last = newItems.last { log("fetchAjaxPage: last=\(last.pageURL.absoluteString)") }

            if newItems.isEmpty {
                log("fetchAjaxPage: 0 items — marking paginationFailed")
                paginationFailed = true
                isLoadingMore    = false
                return
            }

            hasNextPage = true
            paginationFailed = false
            allItems.append(contentsOf: newItems)
            currentPage = page

            let snapshot = allItems
            // Only cache first page to avoid storing huge accumulated data
            if let url = currentURL, !snapshot.isEmpty, currentPage <= 1 {
                let key = parser?.cacheURL(for: url) ?? url
                Task { await GalleryCache.save(snapshot, for: key) }
            }
            state         = .done(snapshot)
            isLoadingMore = false

            // Phase 2: collect decrypted thumbnails in background (non-blocking).
            if let thumbJS = thumbnailJS {
                Task { await self.fetchThumbnails(thumbJS, for: newItems) }
            }
        } catch {
            log("fetchAjaxPage: ERROR \(error.localizedDescription)")
            // Show error if we're in a loading state (covers goToPage + initial loads)
            if case .loading = state {
                state = .failed("加载失败：\(error.localizedDescription)")
            }
            paginationFailed = true
            isLoadingMore = false
        }
    }

    /// Phase 2: run thumbnailJS, parse the url→dataURI map, update items in-place.
    private func fetchThumbnails(_ js: String, for items: [ParsedItem]) async {
        log("fetchThumbnails: starting for \(items.count) items")
        do {
            let raw = try await runPageJS(js, page: 0)
            guard let data = raw.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  !map.isEmpty else {
                log("fetchThumbnails: empty or invalid map")
                return
            }
            log("fetchThumbnails: got \(map.count) thumbnails")

            // Update allItems where thumbnail was empty and map has a data URI.
            var updated = 0
            for i in allItems.indices {
                if allItems[i].thumbnail == nil,
                   let dataURI = map[allItems[i].pageURL.absoluteString],
                   let url = URL(string: dataURI) {
                    allItems[i] = ParsedItem(
                        title: allItems[i].title,
                        pageURL: allItems[i].pageURL,
                        thumbnail: url,
                        duration: allItems[i].duration,
                        extra: allItems[i].extra
                    )
                    updated += 1
                }
            }
            log("fetchThumbnails: updated \(updated) items")
            if updated > 0 {
                state = .done(allItems)
            }
        } catch {
            log("fetchThumbnails: ERROR \(error.localizedDescription)")
        }
    }

    /// Shared helper: run async JS in the .page content world with a 15 s timeout.
    private func runPageJS(_ js: String, page: Int) async throws -> String {
        nonisolated(unsafe) var resumed = false
        return try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                guard !resumed else { return }
                resumed = true
                cont.resume(throwing: URLError(.timedOut))
            }
            webView.callAsyncJavaScript(
                js,
                arguments: ["page": page],
                in: nil,
                in: .page
            ) { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let val):
                if let text = val as? String { cont.resume(returning: text) }
                else if let bytes = try? JSONSerialization.data(withJSONObject: val, options: [.fragmentsAllowed]),
                        let text = String(data: bytes, encoding: .utf8) { cont.resume(returning: text) }
                else { cont.resume(throwing: SiteDefinitionError.invalid("分页脚本没有返回可解析的数据")) }
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - JS extraction (page-1 / webNavigation pages)

    private func extract() async {
        guard let parser else { return }
        guard !isExtracting else { log("extract: skipped (already extracting)"); return }
        isExtracting = true
        loadTimeoutTask?.cancel()

        log("extract: webViewURL=\(webView.url?.absoluteString ?? "nil"), usedFastLoad=\(usedFastLoad)")

        let isMore = isLoadingMore
        if !isMore, case .loading = state { state = .extracting }

        // Skip waitSeconds when we used fast-load (DOM is ready immediately)
        if !usedFastLoad && parser.waitSeconds > 0 {
            log("extract: waiting \(parser.waitSeconds)s for JS rendering")
            try? await Task.sleep(for: .seconds(parser.waitSeconds))
        }

        // Auto-follow: if the parser defines a redirect JS, run it first.
        if let followJS = parser.preNavigateJS {
            let href = try? await WebScript.evaluate(followJS, in: webView) as? String
            if let href, !href.isEmpty, let followURL = URL(string: href) {
                log("extract: preNavigateJS → following \(followURL.absoluteString)")
                isExtracting = false
                startLoadTimeout()
                webView.load(URLRequest(url: followURL))
                return
            }
            log("extract: preNavigateJS → no redirect")
        }

        do {
            guard let jsonString = try await WebScript.evaluate(parser.extractItemsJS, in: webView) as? String,
                  let data = jsonString.data(using: .utf8) else {
                log("extract: extractItemsJS returned nil/empty")
                if !isMore { state = .done(allItems) }
                isLoadingMore = false
                isExtracting = false
                return
            }
            let raw      = try JSONDecoder().decode([RawItem].self, from: data)
            let base     = webView.url ?? currentURL!
            let newItems = Array(raw.compactMap { ParsedItem(from: $0, base: base) }.prefix(30))
            log("extract: got \(newItems.count) items (raw=\(raw.count))")
            if let first = newItems.first {
                log("extract: first item: title=\(first.title), thumb=\(first.thumbnail?.absoluteString ?? "nil")")
            }

            // Pagination detection
            switch parser.paginationMode {
            case .none:
                nextPageURL = nil
                hasNextPage = false

            case .webNavigation(let npJS):
                let nextHref = try? await WebScript.evaluate(npJS, in: webView) as? String
                nextPageURL  = nextHref.flatMap { URL(string: $0) }
                hasNextPage  = false

            case .ajax:
                nextPageURL = nil
                hasNextPage = !newItems.isEmpty
            }

            // Initial load: replace (SWR refresh overwrites stale cache).
            // loadMore: append for infinite scroll.
            if isMore {
                if newItems.isEmpty {
                    // Page loaded but extracted nothing — treat as pagination failure
                    // so the retry button appears instead of silently disappearing.
                    log("extract: isMore=true but 0 items — marking paginationFailed")
                    paginationFailed = true
                    isLoadingMore    = false
                    isExtracting     = false
                    return
                }
                allItems.append(contentsOf: newItems)
                currentPage += 1
            } else {
                allItems = newItems
                currentPage = 1
            }
            let snapshot = allItems

            // Only cache first page to avoid storing huge accumulated data
            if let url = currentURL, !snapshot.isEmpty, currentPage <= 1 {
                Task { await GalleryCache.save(snapshot, for: parser.cacheURL(for: url)) }
            }
            state         = .done(snapshot)
            isLoadingMore = false
            isExtracting  = false
            log("extract: done, total \(snapshot.count) items")
        } catch {
            isLoadingMore = false
            isExtracting  = false
            log("extract: error \(error.localizedDescription)")
            if !isMore { state = .failed("提取失败：\(error.localizedDescription)") }
        }
    }

}

// MARK: - WKNavigationDelegate

extension PageLoader: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.extract() }
    }
    nonisolated func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if WebReaderTLS.handle(challenge, completionHandler: completionHandler) { return }
        completionHandler(.performDefaultHandling, nil)
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoadingMore = false
            if case .loading = self.state { self.state = .failed(error.localizedDescription) }
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoadingMore = false
            if case .loading = self.state { self.state = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Raw JSON item

private struct RawItem: Decodable {
    let title: String; let url: String; let thumbnail: String?
    let duration: String?; let extra: String?
}

private extension ParsedItem {
    init?(from raw: RawItem, base: URL) {
        guard !raw.title.isEmpty,
              let pageURL = URL(string: raw.url, relativeTo: base)?.absoluteURL else { return nil }
        self.init(
            title: raw.title,
            pageURL: pageURL,
            thumbnail: raw.thumbnail.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: base)?.absoluteURL },
            duration: raw.duration ?? "",
            extra: raw.extra ?? ""
        )
    }
}

// MARK: - HiddenWebView

/// Accepts any WKWebView — used by both PageLoader and VideoURLExtractor.
struct HiddenWebView: UIViewRepresentable {
    let webView: WKWebView

    init(loader: PageLoader) { self.webView = loader.webView }
    init(webView: WKWebView) { self.webView = webView }

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
