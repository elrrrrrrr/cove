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
