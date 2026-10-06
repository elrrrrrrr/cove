import WebKit
import Observation

/// Only page navigation and WebKit operations live on the main actor.
/// Both timeout and completion consume the same actor-isolated ticket.
@MainActor final class WebEngine: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private struct Pending {
        let id: UUID
        let navigation: WKNavigation?
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: Pending?
    init(sourceID: String? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SourceWebSession.store(id: sourceID)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    func load(_ url: URL, headers: [String: String] = [:], wait: Double = 0) async throws {
        try Task.checkCancellation()
        try await WebContentPolicy.installBrowsing(webView)
        webView.customUserAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancel()
                var request = URLRequest(url: url); request.timeoutInterval = 25
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let navigation = webView.load(request)
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    self?.complete(id: id, error: URLError(.timedOut))
                }
                pending = Pending(id: id, navigation: navigation, continuation: continuation, timeout: timeout)
            }
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            try Task.checkCancellation()
        } onCancel: { Task { @MainActor [weak self] in self?.complete(id: id, error: CancellationError()) } }
    }
    private func complete(id: UUID, error: Error?) {
        guard let value = pending, value.id == id else { return }
        pending = nil; value.timeout.cancel()
        if let error { webView.stopLoading(); value.continuation.resume(throwing: error) }
        else { value.continuation.resume() }
    }
    func cancel() {
        if let pending { complete(id: pending.id, error: CancellationError()) }
        webView.stopLoading()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pending, pending.navigation === navigation else { return }
        complete(id: pending.id, error: nil)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let pending, pending.navigation === navigation { complete(id: pending.id, error: error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let pending, pending.navigation === navigation { complete(id: pending.id, error: error) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            if let pending { complete(id: pending.id, error: CoveError.message("网页请求失败：HTTP \(response.statusCode)")) }
            return .cancel
        }
        return .allow
    }
    func execute(_ body: String, arguments: [String: Any] = [:], seconds: Double = 15) async throws -> String {
        try Task.checkCancellation()
        let ticket = ScriptTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ticket.continuation = continuation
                ticket.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    ticket.finish(.failure(URLError(.timedOut)))
                }
                let wrapped = "const __coveResult = await (async function(){\n" + body + "\n})(); return typeof __coveResult === 'string' ? __coveResult : JSON.stringify(__coveResult);"
                webView.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, in: .page) { result in
                    switch result {
                    case .failure(let error): ticket.finish(.failure(error))
                    case .success(let value):
                        if let text = value as? String, text.utf16.count <= 4 * 1024 * 1024 { ticket.finish(.success(text)) }
                        else { ticket.finish(.failure(CoveError.message("解析脚本没有返回有效结果"))) }
                    }
                }
            }
        } onCancel: { Task { @MainActor in ticket.finish(.failure(CancellationError())) } }
    }
}

@MainActor private final class ScriptTicket {
    var continuation: CheckedContinuation<String, Error>?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}
