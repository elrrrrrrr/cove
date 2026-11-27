import WebKit
import Foundation
import CryptoKit

// MARK: - Extracted video result

struct VideoResult: Sendable, Equatable {
    let streamURL : URL        // m3u8 / mp4
    let headers   : [String: String]
    /// Page URL for the next episode. The page is re-parsed when playback ends
    /// so expiring CDN signatures are never reused as a playlist.
    let nextPageURL  : URL?
    let episodeNumber: Int?
    let title        : String?

    init(streamURL: URL, headers: [String: String],
         nextPageURL: URL? = nil, episodeNumber: Int? = nil,
         title: String? = nil) {
        self.streamURL = streamURL
        self.headers = headers
        self.nextPageURL = nextPageURL
        self.episodeNumber = episodeNumber
        self.title = title
    }
}

// MARK: - Extractor (WKWebView-based, MainActor)

@Observable
@MainActor
final class VideoURLExtractor {

    enum State: Equatable { case loading, found(VideoResult), notFound }

    var state: State = .loading
    /// Non-nil after a failed extraction — describes what was found on the page.
    var diagnostic: String? = nil
    let webView: WKWebView
    private var navBridge: WebNavigationBridge?
    private var targetURL: URL?
    var originalPageRequest: URLRequest? { targetURL.map { pageRequest(url: $0) } }
    private var definitionID: String?
    private var extractTask: Task<Void, Never>?
    private var loadTimeoutTask: Task<Void, Never>?

    /// Session-scoped bounded cache: hashed (pageURL + JS) → VideoResult with short TTL.
    private struct CacheEntry { let result: VideoResult; let cachedAt: Date }
    private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 600
    private static let cacheLimit = 64
    private var cacheKey: String {
        guard let targetURL else { return "" }
        let input = targetURL.absoluteString + "\0" + Self.extractionJS(for: targetURL, definitionID: definitionID)
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func extractionJS(for url: URL, definitionID: String? = nil) -> String {
        SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)?.extract?.javascript ?? genericJS
    }

    private static let genericJS = #"""
    (function() {
        const video = document.querySelector('video');
        const source = video?.currentSrc || video?.getAttribute('src') || document.querySelector('video source[src]')?.getAttribute('src');
        if (source && !source.startsWith('blob:')) {
            const url = new URL(source, location.href).href;
            return JSON.stringify({url});
        }
        for (const script of document.querySelectorAll('script:not([src])')) {
            const hit = (script.textContent || '').match(/https?:\/\/[^\s'"<>\\]+\.(?:m3u8|mp4)[^\s'"<>\\]*/);
            if (hit) return JSON.stringify({url: hit[0]});
        }
        return 'null';
    })()
    """#

    init() {
        let wv = WebScript.makeWebView()
        self.webView = wv
        self.navBridge = WebNavigationBridge.attach(
            to: wv,
            onFinish: { [weak self] _ in
                guard let self, state == .loading, extractTask == nil else { return }
                startExtraction()
            },
            onFail: { [weak self] _, _ in
                guard let self, case .loading = state else { return }
                state = .notFound
            }
        )
    }

    func load(url: URL, forceRefresh: Bool = false, definitionID: String? = nil) {
        cancel()
        targetURL = url
        self.definitionID = definitionID
        let key = cacheKey
        if !forceRefresh, let entry = Self.cache[key] {
            if Date().timeIntervalSince(entry.cachedAt) <= Self.cacheTTL {
                state = .found(entry.result)
                return
            }
            Self.cache.removeValue(forKey: key)
        }
        // Cancel any previous in-flight work before restarting
        extractTask?.cancel()
        extractTask = nil
        diagnostic = nil
        state = .loading
        webView.load(pageRequest(url: url))
        startLoadTimeout()
    }

    /// Stop any in-flight extraction and WebView navigation.
    func cancel() {
        extractTask?.cancel()
        extractTask = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        webView.stopLoading()
    }

    /// Retry: reload the page from scratch.
    func retry() {
        guard let url = targetURL else { return }
        cancel()
        diagnostic = nil
        state = .loading
        webView.load(pageRequest(url: url))
        startLoadTimeout()
    }

    /// If WebView doesn't fire didFinish within 10s, try extraction anyway.
    private func startLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            // Only fire if extraction hasn't started yet
            if extractTask == nil, case .loading = state {
                startExtraction()
            }
        }
    }

    private func startExtraction() {
        loadTimeoutTask?.cancel()
        extractTask?.cancel()
        extractTask = Task { await extract() }
    }

    private func extract() async {
        guard let url = targetURL else { return }
        if let wait = SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)?.load?.waitSeconds, wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
        }
        let js = Self.extractionJS(for: url, definitionID: definitionID)

        // Try immediately first — media URLs may be embedded in an
        // inline <script> that's fully parsed by the time didFinish fires.
        // Only poll if the first attempt misses (e.g. JS-driven lazy player init).
        let maxAttempts = 15   // 15 × 300 ms = 4.5 s hard timeout

        for attempt in 0 ..< maxAttempts {
            if Task.isCancelled { return }
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if Task.isCancelled { return }
            if let result = await parseResult(from: js) {
                guard !Task.isCancelled, targetURL == url else { return }
                Self.storeCache(result, for: cacheKey)
                state = .found(result)
                return
            }
        }
        guard !Task.isCancelled, targetURL == url else { return }
        await runDiagnostic()
        guard !Task.isCancelled, targetURL == url else { return }
        state = .notFound
    }

    private static func storeCache(_ result: VideoResult, for key: String) {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.cachedAt) <= cacheTTL }
        if cache.count >= cacheLimit, let oldest = cache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[key] = CacheEntry(result: result, cachedAt: now)
    }

    private func pageRequest(url: URL) -> URLRequest {
        let headers = SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)?.load?.headers ?? [:]
        return WebScript.makeRequest(url: url, headers: headers)
    }

    // MARK: - Diagnostic (runs after extraction fails)

    private static let diagnosticJS = """
    (function() {
        const loc  = window.location.href;
        const bodyLen = document.body?.innerHTML?.length ?? 0;

        // Collect every inline <script> that mentions video/url/stream/src
        const scriptHints = [];
        document.querySelectorAll('script:not([src])').forEach(s => {
            const t = s.textContent || '';
            if (/(m3u8|mp4|video_url|stream|hls|src|flashvars|player)/i.test(t)) {
                // Grab first 400 chars of relevant script
                scriptHints.push(t.replace(/\\s+/g, ' ').trim().slice(0, 400));
            }
        });

        // video / source elements
        const videos = [...document.querySelectorAll('video, video source')].map(el => ({
            tag: el.tagName.toLowerCase(),
            src: el.getAttribute('src') || el.src || '',
            type: el.getAttribute('type') || ''
        }));

        // Any m3u8/mp4 hit in full HTML
        const html = document.documentElement.innerHTML;
        const m3u8Hit = (html.match(/https?:\\/\\/[^\\s'"<>\\\\]+\\.m3u8[^\\s'"<>\\\\]*/g) || []).slice(0, 3);
        const mp4Hit  = (html.match(/https?:\\/\\/[^\\s'"<>\\\\]+\\.mp4[^\\s'"<>\\\\]*/g) || []).slice(0, 3);

        // Common player window vars
        const playerVars = ['player','videojs','jwplayer','flowplayer','flv','hls','video_url']
            .filter(k => typeof window[k] !== 'undefined')
            .map(k => k + '=' + String(window[k]).slice(0, 60));

        return JSON.stringify({
            url: loc, bodyLen,
            scripts: scriptHints.slice(0, 3),
            videos, m3u8Hit, mp4Hit, playerVars
        }, null, 2);
    })()
    """

    private func runDiagnostic() async {
        guard let raw = try? await WebScript.boundedString(Self.diagnosticJS, in: webView) else {
            diagnostic = "WebView 无响应"
            return
        }
        diagnostic = raw
        print("\n[VideoURLExtractor] 诊断结果:\n\(raw)\n")
    }

    private func parseResult(from js: String) async -> VideoResult? {
        guard let raw = try? await WebScript.boundedString(js, in: webView),
              raw != "null",
              let data = raw.data(using: .utf8),
              let obj  = try? JSONDecoder().decode(RawVideo.self, from: data),
              let streamURL = WebScript.resolveURL(obj.url, relativeTo: targetURL) else { return nil }
        return VideoResult(
            streamURL: streamURL,
            headers: obj.headers ?? [:],
            nextPageURL: WebScript.resolveURL(obj.nextPageURL, relativeTo: targetURL),
            episodeNumber: obj.episodeNumber,
            title: obj.title
        )
    }

    private struct RawVideo: Decodable {
        let url: String
        let headers: [String: String]?
        let nextPageURL: String?
        let episodeNumber: Int?
        let title: String?
    }
}
