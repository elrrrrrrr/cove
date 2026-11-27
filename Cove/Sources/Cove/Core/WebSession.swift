import SwiftUI
@preconcurrency import WebKit
import CryptoKit

// MARK: - URL & Script Safety

enum WebURLSafety {
    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    static func isMediaURL(_ url: URL) -> Bool {
        isWebURL(url) || url.scheme?.lowercased() == "data"
    }

    static func resolveURL(_ value: String?, relativeTo base: URL?, allowData: Bool = false) -> URL? {
        guard let value, !value.isEmpty,
              let resolved = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
        return (allowData ? isMediaURL(resolved) : isWebURL(resolved)) ? resolved : nil
    }

    static func makeRequest(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = mobileUserAgent,
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    static func stripResourceTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script\b[^>]*>[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<script\b[^/]*/>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<link\b(?![^>]*\brel\s*=\s*["']?(?:next|prev)\b)[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
}

// MARK: - Content Blocker

actor ContentBlocker {
    static let shared = ContentBlocker()
    private var cachedList: WKContentRuleList?

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "contentBlockerEnabled") == nil || defaults.bool(forKey: "contentBlockerEnabled")
    }

    @MainActor static func sync(to webView: WKWebView, defaults: UserDefaults = .standard) async {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard isEnabled(in: defaults),
              let list = try? await shared.ruleList(),
              !Task.isCancelled, isEnabled(in: defaults) else { return }
        controller.removeAllContentRuleLists()
        controller.add(list)
    }

    func ruleList() async throws -> WKContentRuleList {
        if let cachedList { return cachedList }
        guard let url = Bundle.main.url(forResource: "BlockerRules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            throw SiteDefinitionError.invalid("缺少拦截规则")
        }
        let list: WKContentRuleList? = try await Task { @MainActor in
            try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "CoveBlocker", encodedContentRuleList: json)
        }.value
        guard let list else { throw SiteDefinitionError.invalid("拦截规则编译失败") }
        cachedList = list
        return list
    }
}

// MARK: - Shared WKNavigationDelegate & Bounded JS Runner

@MainActor
final class WebNavigationBridge: NSObject, WKNavigationDelegate {
    var onFinish: ((ObjectIdentifier?) -> Void)?
    var onFail: ((ObjectIdentifier?, Error) -> Void)?
    var onResponse: ((WKNavigationResponse) -> WKNavigationResponsePolicy)?

    static func attach(to webView: WKWebView) -> WebNavigationBridge {
        let bridge = WebNavigationBridge()
        webView.navigationDelegate = bridge
        return bridge
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        await MainActor.run { onResponse?(response) ?? .allow }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in onFinish?(id) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(navigation, error: error)
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(navigation, error: error)
    }

    private nonisolated func handleFailure(_ navigation: WKNavigation!, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in onFail?(id, error) }
    }
}

enum WebScript {
    @MainActor
    static func makeWebView(allowsInlineMediaPlayback: Bool = true, gestures: Bool = false) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.customUserAgent = WebURLSafety.mobileUserAgent
        wv.allowsBackForwardNavigationGestures = gestures
        return wv
    }

    @MainActor
    static func boundedString(_ expression: String, in webView: WKWebView, timeout: Duration = .seconds(12)) async throws -> String? {
        try await runBounded("return await (\(expression));", arguments: [:], in: webView, timeout: timeout) { $0 as? String }
    }

    @MainActor
    static func boundedFunction(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView, timeout: Duration = .seconds(15)) async throws -> String {
        try await runBounded(body, arguments: arguments, in: webView, timeout: timeout) { raw in
            if let string = raw as? String { return string }
            if (JSONSerialization.isValidJSONObject(raw) || raw is NSNumber || raw is NSNull),
               let bytes = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
               let string = String(data: bytes, encoding: .utf8) { return string }
            throw SiteDefinitionError.invalid("脚本返回了无效数据")
        }
    }

    @MainActor
    private static func runBounded<T: Sendable>(
        _ body: String, arguments: [String: Any], in webView: WKWebView, timeout: Duration, transform: @escaping (Any) throws -> T
    ) async throws -> T {
        let call = Call<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard call.register(continuation) else { return }
                call.timeout = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    call.finish(.failure(URLError(.timedOut)))
                }
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                    let mapped = result.flatMap { raw in Result { try transform(raw) } }
                    Task { @MainActor in call.finish(mapped) }
                }
            }
        } onCancel: { Task { @MainActor in call.finish(.failure(CancellationError())) } }
    }

    @MainActor
    private final class Call<T: Sendable> {
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        var timeout: Task<Void, Never>?
        func register(_ c: CheckedContinuation<T, Error>) -> Bool {
            if let result { c.resume(with: result); return false }
            continuation = c; return true
        }
        func finish(_ result: Result<T, Error>) {
            guard self.result == nil else { return }
            self.result = result; timeout?.cancel(); timeout = nil
            let c = continuation; continuation = nil; c?.resume(with: result)
        }
    }
}

// MARK: - Domain Results

struct VideoResult: Sendable, Equatable {
    let streamURL: URL
    let headers: [String: String]
    let nextPageURL: URL?
    let episodeNumber: Int?
    let title: String?
}

struct ComicChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let chapterURL: URL
}

struct ComicDetail: Sendable {
    let title: String; let author: String; let status: String
    let tags: [String]; let description: String; let coverURL: URL?
    let chapters: [ComicChapter]
}

// MARK: - Unified Web Extraction & Catalog Session

@Observable
@MainActor
final class WebSession {
    enum CatalogState: Equatable {
        case idle, loading, extracting, done([ParsedItem]), failed(String)
        var isActive: Bool { if case .loading = self { true } else if case .extracting = self { true } else { false } }
    }

    var catalogState: CatalogState = .idle
    var currentPage = 1
    var isLoadingMore = false
    var paginationFailed = false
    var hasNextPage = false
    var nextPageURL: URL?

    var canLoadMore: Bool {
        guard !isLoadingMore, let parser else { return false }
        switch parser.paginationMode {
        case .none: return false
        case .ajax: return hasNextPage
        case .webNavigation: return nextPageURL != nil
        }
    }

    var resolvedBaseURL: URL? { _webView?.url ?? currentURL }
    var originalRequest: URLRequest? { currentURL.map { WebURLSafety.makeRequest(url: $0, headers: currentHeaders) } }

    var webView: WKWebView {
        if let _webView {
            attachWindowIfNeeded(to: _webView)
            return _webView
        }
        let wv = WebScript.makeWebView()
        navBridge = WebNavigationBridge.attach(to: wv)
        _webView = wv
        attachWindowIfNeeded(to: wv)
        Task { [weak wv] in if let wv { await ContentBlocker.sync(to: wv) } }
        return wv
    }

    private func attachWindowIfNeeded(to wv: WKWebView) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let win = UIWindow(windowScene: scene)
        win.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        win.windowLevel = .init(rawValue: -1)
        win.isHidden = false
        win.rootViewController = UIViewController()
        win.rootViewController?.view.addSubview(wv)
        window = win
    }

    private var _webView: WKWebView?
    private var navBridge: WebNavigationBridge?
    private var window: UIWindow?
    private var currentURL: URL?
    private var currentHeaders: [String: String] = [:]
    private var resolvedAuthority: (scheme: String?, host: String, port: Int?)?
    private var parser: SiteParser?
    private var allItems: [ParsedItem] = []
    private var catalogTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var generation = UUID()
    private var preNavigateHops = 0
    private var usedFastLoad = false

    private struct VideoCacheEntry { let result: VideoResult; let date: Date }
    private static var videoCache: [String: VideoCacheEntry] = [:]

    func cancel() {
        generation = UUID()
        catalogTask?.cancel(); catalogTask = nil
        pageTask?.cancel(); pageTask = nil
        _webView?.stopLoading()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // MARK: Catalog & Pagination

    func loadCatalog(url: URL, parser: SiteParser, forceRefresh: Bool = false) {
        catalogTask?.cancel(); pageTask?.cancel()
        generation = UUID()
        let id = generation
        if forceRefresh || self.parser?.portal != parser.portal { resolvedAuthority = nil }
        self.parser = parser
        currentURL = url
        currentHeaders = parser.requestHeaders
        currentPage = 1; hasNextPage = false; nextPageURL = nil
        isLoadingMore = false; paginationFailed = false; preNavigateHops = 0
        allItems = []; catalogState = .loading

        catalogTask = Task {
            let target = await resolvePortalURL(url: url, parser: parser, generation: id)
            guard id == generation, !Task.isCancelled else { return }
            currentURL = target
            await runCatalogPage(url: target, parser: parser, generation: id, append: false)
        }
    }

    func reload() {
        guard let currentURL, let parser else { return }
        loadCatalog(url: currentURL, parser: parser, forceRefresh: true)
    }

    func refresh() async {
        guard let currentURL, let parser else { return }
        catalogTask?.cancel(); pageTask?.cancel()
        generation = UUID()
        let id = generation
        resolvedAuthority = nil
        currentHeaders = parser.requestHeaders
        isLoadingMore = false; paginationFailed = false; preNavigateHops = 0
        let target = await resolvePortalURL(url: currentURL, parser: parser, generation: id)
        guard id == generation, !Task.isCancelled else { return }
        self.currentURL = target
        await runCatalogPage(url: target, parser: parser, generation: id, append: false)
    }

    func loadNextPage() {
        guard !isLoadingMore, let parser else { return }
        isLoadingMore = true; paginationFailed = false
        let next = currentPage + 1
        let id = generation
        switch parser.paginationMode {
        case .none: isLoadingMore = false
        case .ajax(let js, let thumbJS):
            pageTask?.cancel()
            pageTask = Task { await fetchAjaxPage(next, js: js, thumbJS: thumbJS, generation: id, replaceAll: false) }
        case .webNavigation:
            guard let nextURL = nextPageURL else { isLoadingMore = false; return }
            catalogTask?.cancel()
            catalogTask = Task { await runCatalogPage(url: nextURL, parser: parser, generation: id, append: true) }
        }
    }

    func loadPage(_ page: Int) {
        guard let parser else { return }
        switch parser.paginationMode {
        case .ajax(let js, let thumbJS):
            allItems = []; currentPage = page; hasNextPage = false; isLoadingMore = true; catalogState = .loading
            let id = generation
            pageTask?.cancel()
            pageTask = Task { await fetchAjaxPage(page, js: js, thumbJS: thumbJS, generation: id, replaceAll: true) }
        default:
            reload()
        }
    }

    private func resolvePortalURL(url: URL, parser: SiteParser, generation id: UUID) async -> URL {
        guard let portal = parser.portal else { return url }
        if let cached = resolvedAuthority {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
            comps?.scheme = cached.scheme; comps?.host = cached.host; comps?.port = cached.port
            return comps?.url ?? url
        }
        if let resolved = await SitePortalResolver.fetch(config: portal, target: url), id == generation {
            if let host = resolved.host() { resolvedAuthority = (resolved.scheme, host, resolved.port) }
            return resolved
        }
        return url
    }

    private func runCatalogPage(url: URL, parser: SiteParser, generation id: UUID, append: Bool) async {
        do {
            try await loadPage(url: url, mode: parser.needsJS ? "webView" : "auto",
                               headers: parser.requestHeaders, transform: parser.transformScript, timeout: 15)
            guard id == generation, !Task.isCancelled else { return }
            if !append, case .loading = catalogState { catalogState = .extracting }
            if !usedFastLoad && parser.waitSeconds > 0 { try? await Task.sleep(for: .seconds(parser.waitSeconds)) }
            guard id == generation, !Task.isCancelled else { return }

            if let followJS = parser.preNavigateJS, preNavigateHops < 5,
               let href = try? await WebScript.boundedString(followJS, in: webView),
               let next = WebURLSafety.resolveURL(href, relativeTo: resolvedBaseURL), next != resolvedBaseURL {
                preNavigateHops += 1
                await runCatalogPage(url: next, parser: parser, generation: id, append: append)
                return
            }

            guard let raw = try await WebScript.boundedString(parser.extractItemsJS, in: webView),
                  let data = raw.data(using: .utf8),
                  let base = resolvedBaseURL else {
                if append { paginationFailed = true } else { catalogState = .done(allItems) }
                isLoadingMore = false
                return
            }
            let items = try decodeCatalog(data, base: base)
            guard id == generation, !Task.isCancelled else { return }
            if append {
                if items.isEmpty { paginationFailed = true; isLoadingMore = false; return }
                allItems.append(contentsOf: items)
                currentPage += 1
            } else {
                allItems = items
                currentPage = 1
            }
            if case .webNavigation(let npJS) = parser.paginationMode {
                let nextHref = try? await WebScript.boundedString(npJS, in: webView)
                let resolved = WebURLSafety.resolveURL(nextHref, relativeTo: base)
                nextPageURL = resolved != base ? resolved : nil
                hasNextPage = false
            } else if case .ajax = parser.paginationMode {
                nextPageURL = nil; hasNextPage = !items.isEmpty
            } else {
                nextPageURL = nil; hasNextPage = false
            }
            catalogState = .done(allItems)
            isLoadingMore = false
        } catch {
            guard id == generation, !Task.isCancelled else { return }
            isLoadingMore = false
            if append { paginationFailed = true } else { catalogState = .failed("提取失败：\(error.localizedDescription)") }
        }
    }

    private func fetchAjaxPage(_ page: Int, js: String, thumbJS: String?, generation id: UUID, replaceAll: Bool) async {
        do {
            let raw = try await WebScript.boundedFunction(js, arguments: ["page": page], in: webView)
            guard id == generation, !Task.isCancelled,
                  let data = raw.data(using: .utf8), let base = resolvedBaseURL else { isLoadingMore = false; return }
            let items = try decodeCatalog(data, base: base)
            guard !items.isEmpty else { paginationFailed = true; isLoadingMore = false; return }
            hasNextPage = true; paginationFailed = false; currentPage = page
            if replaceAll { allItems = items } else { allItems.append(contentsOf: items) }
            catalogState = .done(allItems)
            isLoadingMore = false
            if let thumbJS, let mapRaw = try? await WebScript.boundedFunction(thumbJS, arguments: ["page": 0], in: webView),
               let mapData = mapRaw.data(using: .utf8),
               let map = try? JSONSerialization.jsonObject(with: mapData) as? [String: String], id == generation {
                var changed = false
                for i in allItems.indices where allItems[i].thumbnail == nil {
                    if let uri = map[allItems[i].pageURL.absoluteString], let u = WebURLSafety.resolveURL(uri, relativeTo: base, allowData: true) {
                        allItems[i] = ParsedItem(title: allItems[i].title, pageURL: allItems[i].pageURL, thumbnail: u,
                                                 duration: allItems[i].duration, extra: allItems[i].extra, titleImage: allItems[i].titleImage)
                        changed = true
                    }
                }
                if changed { catalogState = .done(allItems) }
            }
        } catch {
            guard id == generation, !Task.isCancelled else { return }
            if case .loading = catalogState { catalogState = .failed("加载失败：\(error.localizedDescription)") }
            paginationFailed = true; isLoadingMore = false
        }
    }

    private func decodeCatalog(_ data: Data, base: URL) throws -> [ParsedItem] {
        struct RawItem: Decodable {
            let title: String?; let url: String; let thumbnail: String?
            let duration: String?; let extra: String?; let titleImage: String?
        }
        return Array(try JSONDecoder().decode([RawItem].self, from: data).compactMap { raw -> ParsedItem? in
            let titleImage = WebURLSafety.resolveURL(raw.titleImage, relativeTo: base, allowData: true)
            let rawTitle = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? (titleImage != nil ? "图片标题" : "") : rawTitle
            guard !title.isEmpty, let pageURL = WebURLSafety.resolveURL(raw.url, relativeTo: base) else { return nil }
            return ParsedItem(
                title: title, pageURL: pageURL,
                thumbnail: WebURLSafety.resolveURL(raw.thumbnail, relativeTo: base, allowData: true),
                duration: raw.duration ?? "", extra: raw.extra ?? "", titleImage: titleImage
            )
        }.prefix(100))
    }

    // MARK: Detail Extractors (Video / Comic / Chapter / Article)

    func extractVideo(url: URL, definitionID: String?, forceRefresh: Bool = false) async -> VideoResult? {
        let rule = SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)
        let js = rule?.extract?.javascript ?? Self.genericVideoJS
        let key = SHA256.hash(data: Data((url.absoluteString + "\0" + js).utf8)).map { String(format: "%02x", $0) }.joined()
        if !forceRefresh, let cached = Self.videoCache[key], Date().timeIntervalSince(cached.date) <= 600 { return cached.result }

        currentURL = url; currentHeaders = rule?.load?.headers ?? [:]
        do {
            try await loadPage(url: url, mode: "webView", headers: currentHeaders, transform: nil, timeout: 10)
            if let wait = rule?.load?.waitSeconds, wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            struct RawVideo: Decodable { let url: String; let headers: [String: String]?; let nextPageURL: String?; let episodeNumber: Int?; let title: String? }
            for attempt in 0..<15 {
                try Task.checkCancellation()
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                if let raw = try? await WebScript.boundedString(js, in: webView), raw != "null",
                   let data = raw.data(using: .utf8), let obj = try? JSONDecoder().decode(RawVideo.self, from: data),
                   let streamURL = WebURLSafety.resolveURL(obj.url, relativeTo: url) {
                    let res = VideoResult(streamURL: streamURL, headers: obj.headers ?? [:],
                                          nextPageURL: WebURLSafety.resolveURL(obj.nextPageURL, relativeTo: url),
                                          episodeNumber: obj.episodeNumber, title: obj.title)
                    Self.videoCache = Self.videoCache.filter { Date().timeIntervalSince($0.value.date) <= 600 }
                    if Self.videoCache.count >= 64, let old = Self.videoCache.min(by: { $0.value.date < $1.value.date })?.key {
                        Self.videoCache.removeValue(forKey: old)
                    }
                    Self.videoCache[key] = VideoCacheEntry(result: res, date: Date())
                    return res
                }
            }
        } catch {}
        return nil
    }

    func extractComic(url: URL, definitionID: String?) async throws -> ComicDetail {
        guard let rule = SiteParserRegistry.rule(for: url, role: "comic", definitionID: definitionID),
              let extraction = rule.extract else { throw SiteDefinitionError.invalid("请先配置漫画详情解析规则") }
        currentURL = url; currentHeaders = rule.load?.headers ?? [:]
        try await loadPage(url: url, mode: rule.load?.mode ?? "auto", headers: currentHeaders, transform: rule.load?.transformScript, timeout: 12)
        if let wait = rule.load?.waitSeconds, wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard let raw = try await WebScript.boundedString(extraction.javascript, in: webView),
              let bytes = raw.data(using: .utf8) else { throw SiteDefinitionError.invalid("解析结果为空") }
        struct RawMeta: Decodable {
            struct Ch: Decodable { let id: String?; let title: String?; let url: String }
            let title: String?; let author: String?; let status: String?; let tags: [String]?; let desc: String?; let cover: String?; let chapters: [Ch]
        }
        let meta = try JSONDecoder().decode(RawMeta.self, from: bytes)
        let chapters = meta.chapters.compactMap { ch -> ComicChapter? in
            guard let u = WebURLSafety.resolveURL(ch.url, relativeTo: url) else { return nil }
            return ComicChapter(id: ch.id ?? u.absoluteString, title: ch.title ?? "开始阅读", chapterURL: u)
        }
        guard !chapters.isEmpty else { throw SiteDefinitionError.invalid("未找到章节，请检查解析规则") }
        return ComicDetail(
            title: meta.title ?? "", author: meta.author ?? "", status: meta.status ?? "",
            tags: meta.tags ?? [], description: meta.desc ?? "",
            coverURL: WebURLSafety.resolveURL(meta.cover, relativeTo: url, allowData: true),
            chapters: chapters
        )
    }

    func extractChapterImages(url: URL, definitionID: String?) async throws -> [URL] {
        guard let rule = SiteParserRegistry.rule(for: url, role: "chapter", definitionID: definitionID) else {
            throw SiteDefinitionError.invalid("请先配置章节图片解析规则")
        }
        let headers = rule.load?.headers ?? [:]
        currentURL = url; currentHeaders = headers
        if let cfg = rule.request {
            guard let capture = SitePortalResolver.captures(cfg.capturePattern, in: url.absoluteString).first,
                  let reqURL = WebURLSafety.resolveURL(cfg.urlTemplate.replacingOccurrences(of: "{capture}", with: capture), relativeTo: url) else {
                throw SiteDefinitionError.invalid("无法从地址生成章节请求")
            }
            let (bytes, response) = try await URLSession.shared.data(for: WebURLSafety.makeRequest(url: reqURL, headers: headers, timeout: 15))
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code),
                  let text = String(data: bytes, encoding: .utf8) else { throw SiteDefinitionError.invalid("章节请求失败") }
            let urls = SitePortalResolver.captures(cfg.responsePattern, in: text)
                .filter { v in !(cfg.exclude ?? []).contains { v.contains($0) } }
                .compactMap { WebURLSafety.resolveURL($0, relativeTo: reqURL, allowData: true) }
            guard !urls.isEmpty else { throw SiteDefinitionError.invalid("未找到图片，请检查响应规则") }
            return urls
        }
        guard let extraction = rule.extract else { throw SiteDefinitionError.invalid("缺少章节提取规则") }
        try await loadPage(url: url, mode: "webView", headers: headers, transform: nil, timeout: 12)
        struct RawImages: Decodable { let images: [String] }
        for attempt in 0..<2 {
            try await Task.sleep(for: .seconds(attempt == 0 ? (rule.load?.waitSeconds ?? 0) : 1.5))
            if let raw = try await WebScript.boundedString(extraction.javascript, in: webView),
               let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(RawImages.self, from: data) {
                let urls = parsed.images.compactMap { WebURLSafety.resolveURL($0, relativeTo: url, allowData: true) }
                if !urls.isEmpty { return urls }
            }
        }
        throw SiteDefinitionError.invalid("未找到漫画图片")
    }

    func extractArticle(url: URL, fallbackTitle: String, definitionID: String?) async throws -> ArticleDocument {
        guard ArticleDocument.address(url.absoluteString, base: url) != nil else {
            throw SiteDefinitionError.invalid("图文地址需要 HTTP 或 HTTPS")
        }
        let rule = SiteParserRegistry.rule(for: url, role: "article", definitionID: definitionID)
        currentURL = url; currentHeaders = rule?.load?.headers ?? [:]
        var activeURL = url
        var hops = 0
        while true {
            try await loadPage(url: activeURL, mode: "webView", headers: currentHeaders, transform: nil, timeout: 25, rejectHTTPFailure: true)
            if let wait = rule?.load?.waitSeconds, wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if let follow = rule?.load?.preNavigateExpression ?? rule?.load?.preNavigateScript.map({ "(async function(){\n\($0)\n})()" }),
               let target = try await WebScript.boundedString(follow, in: webView),
               let next = ArticleDocument.address(target, base: activeURL), next != activeURL {
                guard hops < 5 else { throw SiteDefinitionError.invalid("网页跳转次数超过限制") }
                hops += 1; activeURL = next; continue
            }
            break
        }
        let script = rule?.extract?.javascript ?? Self.genericArticleJS
        guard let string = try await WebScript.boundedString(script, in: webView),
              let data = string.data(using: .utf8) else { throw SiteDefinitionError.invalid("规则未返回图文内容") }
        let doc = try await Task.detached(priority: .userInitiated) {
            try ArticleDocument.decode(data, base: activeURL, fallbackTitle: fallbackTitle)
        }.value
        return doc
    }

    // MARK: Core WebView Page Loader

    private func loadPage(
        url: URL, mode: String, headers: [String: String], transform: String?, timeout: TimeInterval, rejectHTTPFailure: Bool = false
    ) async throws {
        usedFastLoad = false
        let wv = webView
        if mode != "webView" {
            let req = WebURLSafety.makeRequest(url: url, headers: headers, timeout: 10)
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                try Task.checkCancellation()
                if let transform {
                    html = (try? await wv.callAsyncJavaScript(transform, arguments: ["html": html], in: nil, contentWorld: .page) as? String) ?? html
                }
                let stripped = await Task.detached(priority: .userInitiated) { WebURLSafety.stripResourceTags(html) }.value
                try Task.checkCancellation()
                usedFastLoad = true
                try await navigateAndAwait(in: wv, timeout: timeout, rejectHTTPFailure: false) { wv.loadHTMLString(stripped, baseURL: url) }
                return
            }
        }
        try Task.checkCancellation()
        let req = WebURLSafety.makeRequest(url: url, headers: headers)
        try await navigateAndAwait(in: wv, timeout: timeout, rejectHTTPFailure: rejectHTTPFailure) { wv.load(req) }
    }

    private func navigateAndAwait(
        in wv: WKWebView, timeout: TimeInterval, rejectHTTPFailure: Bool, trigger: @escaping @MainActor () -> WKNavigation?
    ) async throws {
        guard let bridge = navBridge else { return }
        let waiter = NavWaiter(bridge: bridge)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    waiter.start(continuation: continuation, in: wv, timeout: timeout, rejectHTTPFailure: rejectHTTPFailure, trigger: trigger)
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.cancel(in: wv) }
        }
    }

    @MainActor
    private final class NavWaiter {
        private let bridge: WebNavigationBridge
        private var continuation: CheckedContinuation<Void, Error>?
        private var timer: Task<Void, Never>?
        private var finished = false

        init(bridge: WebNavigationBridge) { self.bridge = bridge }

        func start(
            continuation: CheckedContinuation<Void, Error>,
            in wv: WKWebView,
            timeout: TimeInterval,
            rejectHTTPFailure: Bool,
            trigger: @MainActor () -> WKNavigation?
        ) {
            guard !finished else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            bridge.onResponse = rejectHTTPFailure ? { [weak self] resp in
                if resp.isForMainFrame, let http = resp.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    wv.stopLoading()
                    self?.finish(.failure(SiteDefinitionError.invalid("网页响应 HTTP \(http.statusCode)，可查看原始网页")))
                }
                return .allow
            } : nil
            let navID = trigger().map(ObjectIdentifier.init)
            bridge.onFinish = { [weak self] id in if navID == nil || id == navID { self?.finish(.success(())) } }
            bridge.onFail = { [weak self] id, err in if navID == nil || id == navID { self?.finish(.failure(err)) } }
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(.success(()))
            }
        }

        func cancel(in wv: WKWebView) {
            wv.stopLoading()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true; timer?.cancel(); timer = nil
            bridge.onFinish = nil; bridge.onFail = nil; bridge.onResponse = nil
            continuation?.resume(with: result); continuation = nil
        }
    }

    private static let genericArticleJS = SiteExtraction(fields: [
        "title": .init(selector: "h1, title", text: true),
        "blocks": .init(selector: "article, main, [role=main]", content: true)
    ]).javascript

    private static let genericVideoJS = #"""
    (function() {
        const video = document.querySelector('video');
        const source = video?.currentSrc || video?.getAttribute('src') || document.querySelector('video source[src]')?.getAttribute('src');
        if (source && !source.startsWith('blob:')) return JSON.stringify({url: new URL(source, location.href).href});
        for (const script of document.querySelectorAll('script:not([src])')) {
            const hit = (script.textContent || '').match(/https?:\/\/[^\s'"<>\\]+\.(?:m3u8|mp4)[^\s'"<>\\]*/);
            if (hit) return JSON.stringify({url: hit[0]});
        }
        return 'null';
    })()
    """#
}

// MARK: - Parsing WebView Inspector Sheet

struct ParsingWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        attach(to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) { attach(to: host) }
    private func attach(to host: UIView) {
        if webView.superview !== host {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: host.topAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
        }
    }
}

struct ParsingWebViewSheet: View {
    let webView: WKWebView
    let request: URLRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ParsingWebViewHost(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("原始网页")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("刷新", systemImage: "arrow.clockwise") { webView.load(request) }
                    }
                }
                .onAppear { if webView.url == nil { webView.load(request) } }
        }
    }
}
