import WebKit
import SwiftUI
import os

// MARK: - PageLoader

/// Owns a WKWebView, renders a URL, then runs a JS extractor and returns ParsedItems.
/// Supports SWR: shows cached items immediately, then refreshes in background.
/// Supports pagination: AJAX (fetch via JS) and webNavigation (WKWebView next-page link).
@Observable
@MainActor
final class PageLoader: NSObject {

    enum State: Equatable {
        case idle, loading, extracting, done([ParsedItem]), failed(String)

        var isActive: Bool {
            if case .loading    = self { return true }
            if case .extracting = self { return true }
            return false
        }
    }

    var state         : State = .idle { didSet { if !state.isActive { finishRefreshes() } } }
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
    var originalPageRequest: URLRequest? {
        guard let currentURL else { return nil }
        var request = URLRequest(url: currentURL)
        for (name, value) in parser?.requestHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    var inspectionStatus: String {
        switch state {
        case .idle: "等待加载网页"
        case .loading: "加载网页中…"
        case .extracting: "提取内容中…"
        case .done: isLoadingMore ? "加载下一页中…" : "解析已完成"
        case .failed(let message): "解析失败：\(message)"
        }
    }

    /// Lazily-created WKWebView — avoids blocking the main thread during view init.
    private(set) var webView: WKWebView {
        get {
            if let wv = _webView { return wv }
            let wv = Self.createWebView()
            wv.navigationDelegate = self
            _webView = wv
            // Host in off-screen UIWindow for navigation delegate + JS execution
            let win = UIWindow(frame: Self.renderingFrame)
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
    private var jsCalls: [UUID: PageJSCompletion] = [:]
    private var ajaxTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var loadTimeoutTask: Task<Void, Never>?
    private var isExtracting = false
    private var _backgroundWindow: UIWindow?

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // A nonzero phone viewport lets responsive layouts and virtualized feeds render off-screen.
    private static let renderingFrame = CGRect(x: 0, y: 0, width: 390, height: 844)

    private static func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = SiteWebSession.dataStore
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: renderingFrame, configuration: config)
        wv.customUserAgent = mobileUserAgent
        return wv
    }

    override init() {
        super.init()
        // Lightweight — WKWebView created lazily on first load()
    }

    private static let logger = Logger(subsystem: "Cove", category: "PageLoader")

    private func log(_ msg: String) {
        let ts = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        let truncated = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
        let line = "[\(ts)] \(truncated)"
        parseLog.append(line)
        if parseLog.count > 200 { parseLog.removeFirst(parseLog.count - 200) }
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
        loadTask?.cancel()
        ajaxTask?.cancel()
        for call in jsCalls.values { call.finish(.failure(CancellationError())) }
        jsCalls.removeAll()
        finishRefreshes()
        loadID = UUID()
        _webView?.stopLoading()
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
                else { loadTask = Task { await fetchAndLoad(url: resolved) } }
            } else {
                log("load: portal resolution triggered (urlHost=\(url.host() ?? "nil"))")
                loadTask = Task { await resolvePortalAndLoad(url: url, parser: parser) }
            }
        } else if parser.needsJS {
            log("load: using WebView (needsJS=true)")
            fallbackToWebView(url: url)
        } else {
            log("load: using fast-load (URLSession)")
            loadTask = Task { await fetchAndLoad(url: url) }
        }
    }

    /// URLSession fetch → strip resource tags → loadHTMLString.
    private var usedFastLoad = false

    private func fetchAndLoad(url: URL) async {
        let generation = loadID
        let headers = parser?.requestHeaders ?? [:]
        let transform = parser?.transformScript
        log("fetchAndLoad: fetching \(url.absoluteString)")
        do {
            var request = URLRequest(url: url)
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard generation == loadID, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                log("fetchAndLoad: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) → fallback to WebView")
                fallbackToWebView(url: url); return
            }
            // Decode and scan HTML on a worker; only WebKit calls stay on MainActor.
            let preparation = Task.detached(priority: .userInitiated) { () -> String? in
                guard !Task.isCancelled, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
                return transform == nil ? Self.stripResourceTags(html) : html
            }
            guard var html = await withTaskCancellationHandler(operation: { await preparation.value }, onCancel: { preparation.cancel() }) else {
                guard generation == loadID, !Task.isCancelled else { return }
                fallbackToWebView(url: url); return
            }
            guard generation == loadID, !Task.isCancelled else { return }
            if let transform {
                let transformed = try await webView.callAsyncJavaScript(transform, arguments: ["html": html], in: nil, contentWorld: .page) as? String ?? html
                guard generation == loadID, !Task.isCancelled else { return }
                let stripping = Task.detached(priority: .userInitiated) { Self.stripResourceTags(transformed) }
                html = await withTaskCancellationHandler { await stripping.value } onCancel: { stripping.cancel() }
            }
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAndLoad: prepared HTML, loading")
            usedFastLoad = true
            webView.loadHTMLString(html, baseURL: url)
            startLoadTimeout()
        } catch {
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAndLoad: error \(WebScript.message(for: error)) → fallback to WebView")
            fallbackToWebView(url: url)
        }
    }

    nonisolated static func stripResourceTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script\b[^>]*>[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<script\b[^/]*/>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<link\b[^>]*>"#, with: "", options: .regularExpression)
    }

    private func resolvePortalAndLoad(url: URL, parser: SiteParser) async {
        let generation = loadID
        log("resolvePortal: portal=\(parser.portalURL!), target=\(url.absoluteString)")
        let loadURL: URL
        if let resolved = await SitePortalResolver.fetch(config: parser.portal ?? SitePortal(url: parser.portalURL!), target: url) {
            guard generation == loadID, !Task.isCancelled else { return }
            log("resolvePortal: resolved → \(resolved.absoluteString)")
            resolvedHost = resolved.host()
            currentURL = resolved
            loadURL = resolved
        } else {
            guard generation == loadID, !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        reload()
        let id = UUID()
        await withTaskCancellationHandler {
            guard state.isActive, !Task.isCancelled else { return }
            await withCheckedContinuation { refreshWaiters[id] = $0 }
        } onCancel: { Task { @MainActor in self.refreshWaiters.removeValue(forKey: id)?.resume() } }
    }

    private func finishRefreshes() {
        let pending = refreshWaiters.values
        refreshWaiters.removeAll()
        for waiter in pending { waiter.resume() }
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
            ajaxTask?.cancel()
            ajaxTask = Task { await fetchAjaxPage(nextPage, js: js, thumbnailJS: thumbnailJS) }
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
            ajaxTask?.cancel()
            ajaxTask = Task { await fetchAjaxPage(prevPage, js: js, thumbnailJS: thumbnailJS) }
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
            ajaxTask?.cancel()
            ajaxTask = Task { await fetchAjaxPage(page, js: js, thumbnailJS: thumbnailJS) }
        case .webNavigation:
            // Web-navigation sites: reload from scratch (URL reconstruction is site-specific)
            reload()
        }
    }

    // MARK: - AJAX page fetch

    private func fetchAjaxPage(_ page: Int, js: String, thumbnailJS: String? = nil) async {
        let generation = loadID
        log("fetchAjaxPage: page=\(page), webViewURL=\(webView.url?.absoluteString ?? "nil")")
        do {
            let raw = try await runPageJS(js, page: page)
            guard generation == loadID, !Task.isCancelled else { return }

            guard let data = raw.data(using: .utf8) else {
                isLoadingMore = false; return
            }
            let decoded  = try JSONDecoder().decode([RawItem].self, from: data)
            let base     = webView.url ?? currentURL!
            let newItems = Array(decoded.compactMap { ParsedItem(from: $0, base: base) }.prefix(30))
            let more = try await moreAvailable(default: true)
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAjaxPage: got \(newItems.count) items (raw=\(decoded.count))")
            if let first = newItems.first { log("fetchAjaxPage: first=\(first.pageURL.absoluteString)") }
            if let last = newItems.last { log("fetchAjaxPage: last=\(last.pageURL.absoluteString)") }

            if newItems.isEmpty {
                if !more {
                    hasNextPage = false; paginationFailed = false; isLoadingMore = false
                    state = .done(allItems)
                    return
                }
                log("fetchAjaxPage: 0 items — marking paginationFailed")
                paginationFailed = true
                isLoadingMore    = false
                return
            }

            hasNextPage = more
            paginationFailed = false
            appendUnique(newItems)
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
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAjaxPage: ERROR \(WebScript.message(for: error))")
            // Show error if we're in a loading state (covers goToPage + initial loads)
            if case .loading = state {
                state = .failed("加载失败：\(WebScript.message(for: error))")
            }
            paginationFailed = true
            isLoadingMore = false
        }
    }

    private func moreAvailable(default fallback: Bool) async throws -> Bool {
        guard let expression = parser?.hasMoreExpression else { return fallback }
        let value = try await WebScript.boundedString(SiteScript.jsonExpression(expression), in: webView)
        guard value == "true" || value == "false" else { throw SiteDefinitionError.invalid("hasMoreExpression 必须返回布尔值") }
        return value == "true"
    }

    private func appendUnique(_ items: [ParsedItem]) {
        var urls = Set(allItems.map(\.pageURL))
        allItems.append(contentsOf: items.filter { urls.insert($0.pageURL).inserted })
    }

    /// Phase 2: run thumbnailJS, parse the url→dataURI map, update items in-place.
    private func fetchThumbnails(_ js: String, for items: [ParsedItem]) async {
        let generation = loadID
        log("fetchThumbnails: starting for \(items.count) items")
        do {
            let raw = try await runPageJS(js, page: 0)
            guard generation == loadID, !Task.isCancelled else { return }
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
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchThumbnails: ERROR \(WebScript.message(for: error))")
        }
    }

    /// Shared helper: run async JS in the .page content world with a 15 s timeout.
    private func runPageJS(_ js: String, page: Int) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = PageJSCompletion(continuation)
                jsCalls[id] = completion
                completion.timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.finishJS(id, result: .failure(URLError(.timedOut)))
                }
                webView.callAsyncJavaScript(js, arguments: ["page": page], in: nil, in: .page) { [weak self] result in
                    let value: Result<String, Error>
                    switch result {
                    case .success(let raw):
                        if let string = raw as? String { value = .success(string) }
                        else if let bytes = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
                                let string = String(data: bytes, encoding: .utf8) { value = .success(string) }
                        else { value = .failure(SiteDefinitionError.invalid("分页脚本没有返回可解析的数据")) }
                    case .failure(let error): value = .failure(error)
                    }
                    self?.finishJS(id, result: value)
                }
            }
        } onCancel: { Task { @MainActor in self.finishJS(id, result: .failure(CancellationError())) } }
    }

    private func finishJS(_ id: UUID, result: Result<String, Error>) {
        jsCalls.removeValue(forKey: id)?.finish(result)
    }

    // MARK: - JS extraction (page-1 / webNavigation pages)

    private func extract() async {
        let generation = loadID
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

        guard generation == loadID, !Task.isCancelled else { return }

        // Auto-follow: if the parser defines a redirect JS, run it first.
        if let followJS = parser.preNavigateJS {
            let href = try? await WebScript.evaluate(followJS, in: webView) as? String
            guard generation == loadID, !Task.isCancelled else { return }
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
            let value = try await WebScript.evaluate(parser.extractItemsJS, in: webView)
            guard generation == loadID, !Task.isCancelled else { return }
            guard let jsonString = value as? String, let data = jsonString.data(using: .utf8) else {
                log("extract: extractItemsJS returned nil/empty")
                if !isMore { state = .done(allItems) }
                isLoadingMore = false
                isExtracting = false
                return
            }
            guard generation == loadID, !Task.isCancelled else { return }
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
                guard generation == loadID, !Task.isCancelled else { return }
                nextPageURL  = nextHref.flatMap { URL(string: $0) }
                hasNextPage  = false

            case .ajax:
                let more = try await moreAvailable(default: !newItems.isEmpty)
                guard generation == loadID, !Task.isCancelled else { return }
                nextPageURL = nil
                hasNextPage = more
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
                appendUnique(newItems)
                currentPage += 1
            } else {
                allItems = []
                appendUnique(newItems)
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
            guard generation == loadID, !Task.isCancelled else { return }
            isLoadingMore = false
            isExtracting  = false
            log("extract: error \(WebScript.message(for: error))")
            if !isMore { state = .failed("提取失败：\(WebScript.message(for: error))") }
        }
    }

}

@MainActor private final class PageJSCompletion {
    private var continuation: CheckedContinuation<String, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func finish(_ result: Result<String, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}

// MARK: - WKNavigationDelegate

extension PageLoader: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.extract() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            self.isLoadingMore = false
            if case .loading = self.state { self.state = .failed(WebScript.message(for: error)) }
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            self.isLoadingMore = false
            if case .loading = self.state { self.state = .failed(WebScript.message(for: error)) }
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

    func makeUIView(context: Context) -> ParsingWebViewContainer { ParsingWebViewContainer(webView: webView, accessibilityHidden: true) }
    func updateUIView(_ uiView: ParsingWebViewContainer, context: Context) {}
    static func dismantleUIView(_ uiView: ParsingWebViewContainer, coordinator: ()) { uiView.restore() }
}
