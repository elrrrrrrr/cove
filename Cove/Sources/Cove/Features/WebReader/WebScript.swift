import WebKit

@MainActor enum WebScript {
    nonisolated static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    nonisolated static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    nonisolated static func isMediaURL(_ url: URL) -> Bool {
        isWebURL(url) || url.scheme?.lowercased() == "data"
    }

    nonisolated static func resolveURL(_ value: String?, relativeTo base: URL?, allowData: Bool = false) -> URL? {
        guard let value, !value.isEmpty,
              let resolved = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
        return (allowData ? isMediaURL(resolved) : isWebURL(resolved)) ? resolved : nil
    }

    static func makeRequest(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = nil,
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    static func loadHTMLOrFallback(url: URL, headers: [String: String] = [:], in webView: WKWebView) async {
        let request = makeRequest(url: url, headers: headers, userAgent: webView.customUserAgent ?? mobileUserAgent, timeout: 10)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                let preparation = Task.detached(priority: .userInitiated) { stripResourceTags(html) }
                let stripped = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
                guard !Task.isCancelled else { return }
                webView.loadHTMLString(stripped, baseURL: url)
                return
            }
        } catch {}
        guard !Task.isCancelled else { return }
        webView.load(request)
    }

    static func makeWebView(
        frame: CGRect = .zero,
        allowsInlineMediaPlayback: Bool = false,
        mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes? = nil,
        allowsBackForwardNavigationGestures: Bool = false
    ) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        if let mediaTypesRequiringUserActionForPlayback {
            config.mediaTypesRequiringUserActionForPlayback = mediaTypesRequiringUserActionForPlayback
        }
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: frame, configuration: config)
        wv.customUserAgent = mobileUserAgent
        wv.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        return wv
    }

    nonisolated static func stripResourceTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script\b[^>]*>[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<script\b[^/]*/>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<link\b(?![^>]*\brel\s*=\s*["']?(?:next|prev)\b)[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Execute expressions, including Promise-returning extraction hooks, in the page context.
    static func evaluate(_ expression: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return await (\(expression));", arguments: [:], in: nil, contentWorld: .page)
    }

    static func string(_ expression: String, in webView: WKWebView) async throws -> String? {
        try await evaluate(expression, in: webView) as? String
    }

    static func boundedString(_ expression: String, in webView: WKWebView, timeout: Duration = .seconds(12)) async throws -> String? {
        try await runBounded("return await (\(expression));", arguments: [:], in: webView, timeout: timeout) { $0 as? String }
    }

    static func boundedFunction(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView, timeout: Duration = .seconds(15)) async throws -> String {
        try await runBounded(body, arguments: arguments, in: webView, timeout: timeout) { raw in
            if let string = raw as? String { return string }
            if (JSONSerialization.isValidJSONObject(raw) || raw is NSNumber || raw is NSNull),
               let bytes = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
               let string = String(data: bytes, encoding: .utf8) { return string }
            throw SiteDefinitionError.invalid("分页脚本没有返回可解析的数据")
        }
    }

    private static func runBounded<T: Sendable>(
        _ body: String,
        arguments: [String: Any],
        in webView: WKWebView,
        timeout: Duration,
        transform: @escaping (Any) throws -> T
    ) async throws -> T {
        let call = ScriptCall<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard call.register(continuation) else { return }
                call.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    call.finish(.failure(URLError(.timedOut)))
                }
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                    let mapped: Result<T, Error> = result.flatMap { raw in
                        Result { try transform(raw) }
                    }
                    Task { @MainActor in call.finish(mapped) }
                }
            }
        } onCancel: { Task { @MainActor in call.finish(.failure(CancellationError())) } }
    }
}

@MainActor final class WebNavigationBridge: NSObject, WKNavigationDelegate {
    private let onFinish: @MainActor (ObjectIdentifier?) -> Void
    private let onFail: @MainActor (ObjectIdentifier?, Error) -> Void
    private let onResponse: (@MainActor (WKNavigationResponse) -> WKNavigationResponsePolicy)?

    init(
        onFinish: @escaping @MainActor (ObjectIdentifier?) -> Void,
        onFail: @escaping @MainActor (ObjectIdentifier?, Error) -> Void,
        onResponse: (@MainActor (WKNavigationResponse) -> WKNavigationResponsePolicy)? = nil
    ) {
        self.onFinish = onFinish
        self.onFail = onFail
        self.onResponse = onResponse
    }

    @discardableResult
    static func attach(
        to webView: WKWebView,
        onFinish: @escaping @MainActor (ObjectIdentifier?) -> Void,
        onFail: @escaping @MainActor (ObjectIdentifier?, Error) -> Void,
        onResponse: (@MainActor (WKNavigationResponse) -> WKNavigationResponsePolicy)? = nil
    ) -> WebNavigationBridge {
        let bridge = WebNavigationBridge(onFinish: onFinish, onFail: onFail, onResponse: onResponse)
        webView.navigationDelegate = bridge
        return bridge
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        await MainActor.run { onResponse?(response) ?? .allow }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in onFinish(id) }
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
        Task { @MainActor in onFail(id, error) }
    }
}

@MainActor private final class ScriptCall<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    var timeout: Task<Void, Never>?
    func register(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        if let result { continuation.resume(with: result); return false }
        self.continuation = continuation; return true
    }
    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        let value = continuation; continuation = nil; value?.resume(with: result)
    }
}
