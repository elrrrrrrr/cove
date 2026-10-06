import WebKit

@MainActor enum WebScript {
    /// Execute expressions, including Promise-returning extraction hooks, in the page context.
    static func evaluate(_ expression: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return await (\(expression));", arguments: [:], in: nil, contentWorld: .page)
    }

    static func string(_ expression: String, in webView: WKWebView) async throws -> String? {
        try await evaluate(expression, in: webView) as? String
    }
}
