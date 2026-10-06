import WebKit
import Foundation

// MARK: - Extracted video result

struct VideoResult: Sendable, Equatable {
    let streamURL : URL        // m3u8 / mp4
    let type      : StreamType
    let headers   : [String: String]
    /// Page URL for the next episode. The page is re-parsed when playback ends
    /// so expiring CDN signatures are never reused as a playlist.
    let nextPageURL  : URL?
    let episodeNumber: Int?
    let episodeCount : Int?
    let title        : String?
    enum StreamType: Equatable { case hls, mp4, unknown }

    init(streamURL: URL, type: StreamType, headers: [String: String],
         nextPageURL: URL? = nil, episodeNumber: Int? = nil,
         episodeCount: Int? = nil, title: String? = nil) {
        self.streamURL = streamURL
        self.type = type
        self.headers = headers
        self.nextPageURL = nextPageURL
        self.episodeNumber = episodeNumber
        self.episodeCount = episodeCount
        self.title = title
    }
}

// MARK: - Shared detail rules

enum DetailParserRegistry {
    static func js(for url: URL, definitionID: String? = nil) -> String {
        SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)?.extract?.javascript ?? genericJS
    }
    static func tagsJS(for url: URL, definitionID: String? = nil) -> String? {
        guard let script = SiteParserRegistry.rule(for: url, role: "tags", definitionID: definitionID)?.extract?.javascript else { return nil }
        return "(async function(){ const raw = await (\(script)); const value = typeof raw === 'string' ? JSON.parse(raw) : raw; return JSON.stringify(Array.isArray(value) ? value : value?.tags || []); })()"
    }
    private static let genericJS = #"""
    (function() {
        const video = document.querySelector('video');
        const source = video?.currentSrc || video?.getAttribute('src') || document.querySelector('video source[src]')?.getAttribute('src');
        if (source && !source.startsWith('blob:')) {
            const url = new URL(source, location.href).href;
            return JSON.stringify({url, type: url.includes('.m3u8') ? 'hls' : 'mp4'});
        }
        for (const script of document.querySelectorAll('script:not([src])')) {
            const hit = (script.textContent || '').match(/https?:\/\/[^\s'"<>\\]+\.(?:m3u8|mp4)[^\s'"<>\\]*/);
            if (hit) return JSON.stringify({url: hit[0], type: hit[0].includes('.m3u8') ? 'hls' : 'mp4'});
        }
        return 'null';
    })()
    """#
}

// MARK: - Extractor (WKWebView-based, MainActor)

@Observable
@MainActor
final class VideoURLExtractor: NSObject {

    enum State: Equatable { case loading, found(VideoResult), notFound }

    var state: State = .loading
    /// Tags extracted by the configured detail-page rule.
    var detailTags: [String] = []
    /// Non-nil after a failed extraction — describes what was found on the page.
    var diagnostic: String? = nil
    let webView: WKWebView
    private var targetURL: URL?
    private var definitionID: String?
    private var extractTask: Task<Void, Never>?
    private var loadTimeoutTask: Task<Void, Never>?

    /// Session-scoped cache: pageURL → VideoResult.
    /// m3u8 CDN tokens may expire, so we don't persist to disk.
    private static var cache: [String: VideoResult] = [:]
    private var cacheKey: String {
        guard let targetURL else { return "" }
        return targetURL.absoluteString + DetailParserRegistry.js(for: targetURL, definitionID: definitionID)
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
    }

    func load(url: URL, forceRefresh: Bool = false, definitionID: String? = nil) {
        cancel()
        targetURL = url
        self.definitionID = definitionID
        if !forceRefresh, let cached = Self.cache[cacheKey] {
            state = .found(cached)
            return
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
        let js = DetailParserRegistry.js(for: url, definitionID: definitionID)

        // Extract configured detail-page tags on the first pass
        if let tagsJS = DetailParserRegistry.tagsJS(for: url, definitionID: definitionID) {
            await extractTags(js: tagsJS)
        }

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
                Self.cache[cacheKey] = result
                state = .found(result)
                return
            }
        }
        guard !Task.isCancelled, targetURL == url else { return }
        await runDiagnostic()
        guard !Task.isCancelled, targetURL == url else { return }
        state = .notFound
    }

    private func pageRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in SiteParserRegistry.rule(for: url, role: "video", definitionID: definitionID)?.load?.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func extractTags(js: String) async {
        guard let raw = try? await WebScript.evaluate(js, in: webView) as? String,
              let data = raw.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data) else { return }
        detailTags = tags
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
        guard let raw = try? await webView.evaluateJavaScript(Self.diagnosticJS) as? String else {
            diagnostic = "WebView 无响应"
            return
        }
        diagnostic = raw
        print("\\n[VideoURLExtractor] 诊断结果:\\n\\(raw)\\n")
    }

    private func parseResult(from js: String) async -> VideoResult? {
        guard let raw = try? await WebScript.evaluate(js, in: webView) as? String,
              raw != "null",
              let data = raw.data(using: .utf8),
              let obj  = try? JSONDecoder().decode(RawVideo.self, from: data),
              let streamURL = URL(string: obj.url, relativeTo: targetURL)?.absoluteURL else { return nil }
        let t: VideoResult.StreamType = (obj.type ?? (streamURL.pathExtension == "m3u8" ? "hls" : "mp4")) == "hls" ? .hls
                                      : obj.type == "mp4"  ? .mp4 : .unknown
        return VideoResult(
            streamURL: streamURL,
            type: t,
            headers: obj.headers ?? [:],
            nextPageURL: obj.nextPageURL.flatMap { URL(string: $0, relativeTo: targetURL)?.absoluteURL },
            episodeNumber: obj.episodeNumber,
            episodeCount: obj.episodeCount,
            title: obj.title
        )
    }

    private struct RawVideo: Decodable {
        let url: String
        let type: String?
        let headers: [String: String]?
        let nextPageURL: String?
        let episodeNumber: Int?
        let episodeCount: Int?
        let title: String?
    }
}

extension VideoURLExtractor: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in self.startExtraction() }
    }
    nonisolated func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if WebReaderTLS.handle(challenge, completionHandler: completionHandler) { return }
        completionHandler(.performDefaultHandling, nil)
    }
    nonisolated func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        Task { @MainActor in self.state = .notFound }
    }
    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        Task { @MainActor in self.state = .notFound }
    }
}
