import WebKit

@Observable @MainActor final class ArticleLoader: NSObject {
    enum State: Equatable { case idle, loading, loaded(ArticleDocument), failed(String) }
    var state: State = .idle
    private var storedWebView: WKWebView?
    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let config = WKWebViewConfiguration(); config.websiteDataStore = SiteWebSession.dataStore
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; storedWebView = view; return view
    }
    private(set) var request: URLRequest?
    private var extraction: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var definitionID: String?
    private var fallbackTitle = ""
    private var redirects = 0
    private var navigationID: ObjectIdentifier?

    func load(url: URL, title: String, definitionID: String?) {
        cancel(); fallbackTitle = title; self.definitionID = definitionID; redirects = 0
        guard ArticleDocument.address(url.absoluteString, base: url) != nil else {
            state = .failed("图文地址需要 HTTP 或 HTTPS"); return
        }
        state = .loading
        var request = URLRequest(url: url)
        for (key, value) in rule(for: url)?.load?.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        self.request = request; navigate(request)
        let id = generation
        timeout = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard generation == id, state == .loading else { return }
            fail("网页加载超时，可查看原始网页")
        }
    }

    func cancel() {
        generation = UUID(); extraction?.cancel(); extraction = nil
        navigationID = nil
        timeout?.cancel(); timeout = nil; storedWebView?.stopLoading()
        if state == .loading { state = .idle }
    }

    private func rule(for url: URL, allowRequestFallback: Bool = false) -> SiteRule? {
        if let match = SiteParserRegistry.rule(for: url, role: "article", definitionID: definitionID) { return match }
        // Login redirects on the same origin still need the configured extractor's diagnostics.
        guard allowRequestFallback, let original = request?.url, original.scheme == url.scheme,
              original.host == url.host, original.port == url.port else { return nil }
        return SiteParserRegistry.rule(for: original, role: "article", definitionID: definitionID)
    }

    private func navigate(_ request: URLRequest) { navigationID = webView.load(request).map(ObjectIdentifier.init) }

    private func extract() {
        guard state == .loading, let url = webView.url ?? request?.url else { return }
        extraction?.cancel()
        let id = generation, rule = rule(for: url, allowRequestFallback: true)
        extraction = Task {
            do {
                if let wait = rule?.load?.waitSeconds, wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                try Task.checkCancellation()
                if let follow = rule?.load?.preNavigateExpression ?? rule?.load?.preNavigateScript.map({ "(async function(){\n\($0)\n})()" }),
                   let target = try await WebScript.boundedString(follow, in: webView),
                   let next = ArticleDocument.address(target, base: url), next != url {
                    guard generation == id, state == .loading else { return }
                    guard redirects < 5 else { throw SiteDefinitionError.invalid("网页跳转次数超过限制") }
                    redirects += 1; navigate(URLRequest(url: next)); return
                }
                let script = rule?.extract?.javascript ?? Self.genericExtraction.javascript
                guard let string = try await WebScript.boundedString(script, in: webView), let data = string.data(using: .utf8) else {
                    throw SiteDefinitionError.invalid("规则未返回图文内容")
                }
                let title = fallbackTitle
                let work = Task.detached(priority: .userInitiated) { try ArticleDocument.decode(data, base: url, fallbackTitle: title) }
                let document = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == id, !Task.isCancelled, state == .loading else { return }
                timeout?.cancel(); timeout = nil; state = .loaded(document)
            } catch {
                guard generation == id, !Task.isCancelled, state == .loading else { return }
                fail(WebScript.message(for: error))
            }
        }
    }

    private func fail(_ message: String) {
        timeout?.cancel(); timeout = nil; extraction?.cancel(); extraction = nil
        webView.stopLoading(); state = .failed(message)
    }

    private static let genericExtraction = SiteExtraction(fields: [
        "title": .init(selector: "h1, title", text: true),
        "blocks": .init(selector: "article, main, [role=main]", content: true)
    ])
}

extension ArticleLoader: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, !(200...299).contains(http.statusCode), state == .loading {
            timeout?.cancel(); timeout = nil; extraction?.cancel(); extraction = nil
            state = .failed("网页响应 HTTP \(http.statusCode)，可查看原始网页")
        }
        return .allow
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in guard id == self.navigationID else { return }; self.extract() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in
            guard id == self.navigationID, (error as NSError).code != NSURLErrorCancelled, self.state == .loading else { return }
            self.fail(error.localizedDescription)
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in
            guard id == self.navigationID, (error as NSError).code != NSURLErrorCancelled, self.state == .loading else { return }
            self.fail(error.localizedDescription)
        }
    }
}
