import WebKit

@MainActor enum WebContentPolicy {
    private static var cached: [String: WKContentRuleList] = [:]
    static func installEPUB(_ view: WKWebView) async throws {
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let policy = try await rule(id: "Cove.EPUB.Offline.v2", rules: rules)
        view.configuration.userContentController.add(policy)
    }
    static func installBrowsing(_ view: WKWebView) async throws {
        view.configuration.userContentController.removeAllContentRuleLists()
        guard UserDefaults.standard.object(forKey: "contentBlockerEnabled") as? Bool != false,
              let file = Bundle.main.url(forResource: "BlockerRules", withExtension: "json") else { return }
        let rules = try await Task.detached { try String(contentsOf: file, encoding: .utf8) }.value
        view.configuration.userContentController.add(try await rule(id: "Cove.Browsing.v2", rules: rules))
    }
    private static func rule(id: String, rules: String) async throws -> WKContentRuleList {
        if let value = cached[id] { return value }
        guard let value = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: rules) else {
            throw CoveError.message("无法加载网页内容策略")
        }
        cached[id] = value
        return value
    }
}
