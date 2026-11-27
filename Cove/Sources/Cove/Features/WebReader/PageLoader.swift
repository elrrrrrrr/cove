import WebKit
import SwiftUI
import os

// MARK: - PageLoader

/// Owns a WKWebView, renders a URL, then runs a JS extractor and returns ParsedItems.
/// Supports SWR: shows cached items immediately, then refreshes in background.
/// Supports pagination: AJAX (fetch via JS) and webNavigation (WKWebView next-page link).
@Observable
@MainActor
final class PageLoader {

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

    var currentURL: URL?
    private var resolvedAuthority: (scheme: String?, host: String, port: Int?)?

    /// The URL the WebView actually settled on (may differ from currentURL after redirects/preNavigateJS).
    var resolvedBaseURL: URL? { _webView?.url ?? currentURL }
    var currentWebViewURL: URL? { _webView?.url }
    var originalPageRequest: URLRequest? {
        currentURL.map { WebScript.makeRequest(url: $0, headers: parser?.requestHeaders ?? [:]) }
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
    var webView: WKWebView {
        if let wv = _webView { return wv }
        let wv = WebScript.makeWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), allowsInlineMediaPlayback: true)
        navBridge = WebNavigationBridge.attach(
            to: wv,
            onFinish: { [weak self] _ in
                guard let self, awaitingPageLoad else { return }
                Task { @MainActor [weak self] in await self?.extract() }
            },
            onFail: { [weak self] _, error in
                self?.handleNavigationFailure(error)
            }
        )
        _webView = wv
        // Host in off-screen UIWindow for navigation delegate + JS execution
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let win = UIWindow(windowScene: scene)
            win.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            win.windowLevel = .init(rawValue: -1)
            win.isHidden = false
            win.rootViewController = UIViewController()
            win.rootViewController?.view.addSubview(wv)
            _backgroundWindow = win
        }
        syncBlocker(for: wv)
        return wv
    }
    private var _webView: WKWebView?
    private var navBridge: WebNavigationBridge?
    private var parser   : SiteParser?
    private var allItems : [ParsedItem] = []
    private var ajaxTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var blockerTask: Task<Void, Never>?
    private var loadID = UUID()
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var loadTimeoutTask: Task<Void, Never>?
    private var isExtracting = false
    private var awaitingPageLoad = false
    private var preNavigateCount = 0
    private var _backgroundWindow: UIWindow?

    init() {}

    func cancel() {
        loadTask?.cancel(); loadTask = nil
        ajaxTask?.cancel(); ajaxTask = nil
        loadTimeoutTask?.cancel(); loadTimeoutTask = nil
        blockerTask?.cancel(); blockerTask = nil
        awaitingPageLoad = false
        isExtracting = false
        _webView?.stopLoading()
        _backgroundWindow?.isHidden = true
        _backgroundWindow?.rootViewController = nil
        _backgroundWindow = nil
        finishRefreshes()
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
        finishRefreshes()
        loadID = UUID()
        _webView?.stopLoading()
        if let wv = _webView { syncBlocker(for: wv) }
        if forceRefresh || self.parser?.portal != parser.portal { resolvedAuthority = nil }
        self.parser     = parser
        self.currentURL = url
        currentPage     = 1
        hasNextPage     = false
        nextPageURL     = nil
        isLoadingMore   = false
        paginationFailed = false
        parseLog        = []
        preNavigateCount = 0

        log("load: url=\(url.absoluteString)")
        log("load: parser=\(parser.hostPattern), needsJS=\(parser.needsJS), portal=\(parser.portalURL ?? "nil")")

        let hasCachedContent: Bool
        if case .done = state { hasCachedContent = true } else { hasCachedContent = false }

        if !hasCachedContent || forceRefresh {
            allItems = []
            state    = .loading
        }

        isExtracting = false
        awaitingPageLoad = false
        usedFastLoad = false
        loadTimeoutTask?.cancel()

        // Portal domain resolution: always resolve when parser has a portalURL.
        // This handles stale bookmark domains (e.g. old mirrors that no longer work).
        // Once resolved, cache the authority to skip re-fetching portal on category switch.
        if parser.portalURL != nil {
            if let cached = resolvedAuthority {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                components?.scheme = cached.scheme
                components?.host = cached.host
                components?.port = cached.port
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
            let request = WebScript.makeRequest(url: url, headers: headers, userAgent: WebScript.mobileUserAgent, timeout: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard generation == loadID, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                log("fetchAndLoad: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) → fallback to WebView")
                fallbackToWebView(url: url); return
            }
            // Decode and scan HTML on a worker; only WebKit calls stay on MainActor.
            let preparation = Task.detached(priority: .userInitiated) { () -> String? in
                guard !Task.isCancelled, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
                return transform == nil ? WebScript.stripResourceTags(html) : html
            }
            guard var html = await withTaskCancellationHandler(operation: { await preparation.value }, onCancel: { preparation.cancel() }) else {
                guard generation == loadID, !Task.isCancelled else { return }
                fallbackToWebView(url: url); return
            }
            guard generation == loadID, !Task.isCancelled else { return }
            if let transform {
                let transformed = try await webView.callAsyncJavaScript(transform, arguments: ["html": html], in: nil, contentWorld: .page) as? String ?? html
                guard generation == loadID, !Task.isCancelled else { return }
                let stripping = Task.detached(priority: .userInitiated) { WebScript.stripResourceTags(transformed) }
                html = await withTaskCancellationHandler { await stripping.value } onCancel: { stripping.cancel() }
            }
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAndLoad: prepared HTML, loading")
            usedFastLoad = true
            awaitingPageLoad = true
            webView.loadHTMLString(html, baseURL: url)
            startLoadTimeout()
        } catch {
            guard generation == loadID, !Task.isCancelled else { return }
            log("fetchAndLoad: error \(error.localizedDescription) → fallback to WebView")
            fallbackToWebView(url: url)
        }
    }

    private func resolvePortalAndLoad(url: URL, parser: SiteParser) async {
        let generation = loadID
        log("resolvePortal: portal=\(parser.portalURL!), target=\(url.absoluteString)")
        let loadURL: URL
        if let resolved = await SitePortalResolver.fetch(config: parser.portal ?? SitePortal(url: parser.portalURL!), target: url) {
            guard generation == loadID, !Task.isCancelled else { return }
            log("resolvePortal: resolved → \(resolved.absoluteString)")
            if let host = resolved.host() {
                resolvedAuthority = (resolved.scheme, host, resolved.port)
            }
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
        awaitingPageLoad = true
        webView.load(WebScript.makeRequest(url: url, headers: parser?.requestHeaders ?? [:]))
        startLoadTimeout()
    }

    /// If didFinish hasn't fired within 15 seconds, try extracting from whatever is loaded.
    private func startLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            // Still loading — force extraction attempt
            if case .loading = state {
                await extract()
            } else if isLoadingMore {
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

    private func syncBlocker(for wv: WKWebView) {
        blockerTask?.cancel()
        blockerTask = Task { [weak wv] in
            guard let wv else { return }
            await ContentBlocker.sync(to: wv)
        }
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
                loadTask?.cancel()
                loadTimeoutTask?.cancel()
                isExtracting = false
                log("loadMore: webNavigation → \(next.absoluteString)")
                if p.needsJS {
                    fallbackToWebView(url: next)
                } else {
                    loadTask = Task { await fetchAndLoad(url: next) }
                }
            } else {
                // Construct URL for next page by reloading at page N
                goToPage(nextPage, parser: p)
            }
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

    /// Wait for DOM and extract items; advances pagination and updates cache.
    private func cacheFirstPageIfNeeded(_ snapshot: [ParsedItem]) {
        guard let url = currentURL, !snapshot.isEmpty, currentPage <= 1 else { return }
        let key = parser?.cacheURL(for: url) ?? url
        Task { await GalleryCache.save(snapshot, for: key) }
    }

    private func handleNavigationFailure(_ error: Error) {
        awaitingPageLoad = false
        loadTimeoutTask?.cancel()
        if isLoadingMore {
            paginationFailed = true
            isLoadingMore = false
        }
        if case .loading = state { state = .failed(error.localizedDescription) }
    }

    private func fetchAjaxPage(_ page: Int, js: String, thumbnailJS: String? = nil) async {
        let generation = loadID
        log("fetchAjaxPage: page=\(page), webViewURL=\(webView.url?.absoluteString ?? "nil")")
        do {
            let raw = try await WebScript.boundedFunction(js, arguments: ["page": page], in: webView)
            guard generation == loadID, !Task.isCancelled else { return }

            guard let data = raw.data(using: .utf8), let base = webView.url ?? currentURL else {
                isLoadingMore = false; return
            }
            let newItems = try ParsedItem.decodeCatalog(data, base: base)
            log("fetchAjaxPage: got \(newItems.count) items")
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
            cacheFirstPageIfNeeded(snapshot)
            state         = .done(snapshot)
            isLoadingMore = false

            // Phase 2: collect decrypted thumbnails in background (non-blocking).
            if let thumbJS = thumbnailJS {
                Task { await self.fetchThumbnails(thumbJS, for: newItems) }
            }
        } catch {
            guard generation == loadID, !Task.isCancelled else { return }
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
        let generation = loadID
        log("fetchThumbnails: starting for \(items.count) items")
        do {
            let raw = try await WebScript.boundedFunction(js, arguments: ["page": 0], in: webView)
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
                        extra: allItems[i].extra,
                        titleImage: allItems[i].titleImage
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
            log("fetchThumbnails: ERROR \(error.localizedDescription)")
        }
    }

    // MARK: - JS extraction (page-1 / webNavigation pages)

    private func extract() async {
        let generation = loadID
        guard let parser else { return }
        guard !isExtracting else { log("extract: skipped (already extracting)"); return }
        awaitingPageLoad = false
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
        if let followJS = parser.preNavigateJS, preNavigateCount < 5 {
            let href = try? await WebScript.boundedString(followJS, in: webView)
            guard generation == loadID, !Task.isCancelled else { return }
            if let href, !href.isEmpty,
               let followURL = URL(string: href, relativeTo: webView.url ?? currentURL)?.absoluteURL,
               WebScript.isWebURL(followURL) {
                log("extract: preNavigateJS → following \(followURL.absoluteString)")
                preNavigateCount += 1
                isExtracting = false
                awaitingPageLoad = true
                startLoadTimeout()
                webView.load(URLRequest(url: followURL))
                return
            }
            log("extract: preNavigateJS → no redirect")
        }

        do {
            let jsonString = try await WebScript.boundedString(parser.extractItemsJS, in: webView)
            guard generation == loadID, !Task.isCancelled else { return }
            guard let jsonString, let data = jsonString.data(using: .utf8),
                  let base = webView.url ?? currentURL else {
                log("extract: extractItemsJS returned nil/empty")
                if isMore { paginationFailed = true }
                else { state = .done(allItems) }
                isLoadingMore = false
                isExtracting = false
                return
            }
            guard generation == loadID, !Task.isCancelled else { return }
            let newItems = try ParsedItem.decodeCatalog(data, base: base)
            log("extract: got \(newItems.count) items")
            if let first = newItems.first {
                log("extract: first item: title=\(first.title), thumb=\(first.thumbnail?.absoluteString ?? "nil")")
            }

            // Initial load: replace (SWR refresh overwrites stale cache).
            // loadMore: append for infinite scroll.
            if isMore {
                if newItems.isEmpty {
                    // Page loaded but extracted nothing — preserve nextPageURL and mark
                    // paginationFailed so the retry button retries the same page.
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

            // Pagination detection (only advance nextPageURL after extracting valid items)
            switch parser.paginationMode {
            case .none:
                nextPageURL = nil
                hasNextPage = false

            case .webNavigation(let npJS):
                let loadedURL = webView.url ?? currentURL
                let nextHref = try? await WebScript.boundedString(npJS, in: webView)
                guard generation == loadID, !Task.isCancelled else { return }
                let resolvedNext = WebScript.resolveURL(nextHref, relativeTo: loadedURL)
                nextPageURL  = resolvedNext != loadedURL ? resolvedNext : nil
                hasNextPage  = false

            case .ajax:
                nextPageURL = nil
                hasNextPage = !newItems.isEmpty
            }

            let snapshot = allItems
            cacheFirstPageIfNeeded(snapshot)
            state         = .done(snapshot)
            isLoadingMore = false
            isExtracting  = false
            log("extract: done, total \(snapshot.count) items")
        } catch {
            guard generation == loadID, !Task.isCancelled else { return }
            isLoadingMore = false
            isExtracting  = false
            log("extract: error \(error.localizedDescription)")
            if isMore { paginationFailed = true }
            else { state = .failed("提取失败：\(error.localizedDescription)") }
        }
    }

}

// MARK: - Raw JSON item

private struct RawItem: Decodable {
    let title: String?; let url: String; let thumbnail: String?
    let duration: String?; let extra: String?; let titleImage: String?
}

extension ParsedItem {
    static func decodeCatalog(_ data: Data, base: URL) throws -> [ParsedItem] {
        let raw = try JSONDecoder().decode([RawItem].self, from: data)
        return Array(raw.compactMap { ParsedItem(from: $0, base: base) }.prefix(100))
    }

    private init?(from raw: RawItem, base: URL) {
        let titleImage = WebScript.resolveURL(raw.titleImage, relativeTo: base, allowData: true)
        let rawTitle = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? (titleImage != nil ? "图片标题" : "") : rawTitle
        guard !title.isEmpty,
              let pageURL = WebScript.resolveURL(raw.url, relativeTo: base) else { return nil }
        self.init(
            title: title,
            pageURL: pageURL,
            thumbnail: WebScript.resolveURL(raw.thumbnail, relativeTo: base, allowData: true),
            duration: raw.duration ?? "",
            extra: raw.extra ?? "",
            titleImage: titleImage
        )
    }
}
