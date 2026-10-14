import WebKit

@MainActor enum WebScript {
    static func message(for error: Error) -> String {
        if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
            return String(message.prefix(1024))
        }
        return error.localizedDescription
    }
    /// Execute expressions, including Promise-returning extraction hooks, in the page context.
    static func evaluate(_ expression: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return await (\(expression));", arguments: [:], in: nil, contentWorld: .page)
    }

    static func string(_ expression: String, in webView: WKWebView) async throws -> String? {
        try await evaluate(expression, in: webView) as? String
    }

    static func boundedString(_ expression: String, in webView: WKWebView, timeout: Duration = .seconds(12)) async throws -> String? {
        let call = ScriptStringCall()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                guard call.register(continuation) else { return }
                call.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    call.finish(.failure(URLError(.timedOut)))
                }
                webView.callAsyncJavaScript("return await (\(expression));", arguments: [:], in: nil, in: .page) { result in
                    let text = result.map { $0 as? String }
                    Task { @MainActor in call.finish(text) }
                }
            }
        } onCancel: { Task { @MainActor in call.finish(.failure(CancellationError())) } }
    }
}

@MainActor private final class ScriptStringCall {
    private var continuation: CheckedContinuation<String?, Error>?
    private var result: Result<String?, Error>?
    var timeout: Task<Void, Never>?
    func register(_ continuation: CheckedContinuation<String?, Error>) -> Bool {
        if let result { continuation.resume(with: result); return false }
        self.continuation = continuation; return true
    }
    func finish(_ result: Result<String?, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        let value = continuation; continuation = nil; value?.resume(with: result)
    }
}
