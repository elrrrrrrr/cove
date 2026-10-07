import WebKit

/// Loads and compiles the bundled EasyList content blocking rules into a WKContentRuleList.
actor ContentBlocker {
    static let shared = ContentBlocker()

    private var cachedList: WKContentRuleList?

    func ruleList() async throws -> WKContentRuleList {
        if let cached = cachedList { return cached }

        guard let url = Bundle.main.url(forResource: "BlockerRules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContentBlockerError.rulesNotFound
        }

        // compileContentRuleList must be called on MainActor; use nonisolated wrapper
        let jsonCopy = json
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                do {
                    let result = try await WKContentRuleListStore.default()
                        .compileContentRuleList(
                            forIdentifier: "EasyReaderBlocker",
                            encodedContentRuleList: jsonCopy
                        )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        guard let list else { throw ContentBlockerError.compilationFailed }
        cachedList = list
        return list
    }
}

enum ContentBlockerError: Error {
    case rulesNotFound
    case compilationFailed
}
