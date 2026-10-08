import XCTest
import WebKit
import UIKit
@testable import EasyReader

/// Public fixtures exercise the runner; optional private snapshots exercise local rules.
@MainActor final class SiteRegressionTests: XCTestCase {
    private enum Operation: String, Decodable { case extract, search, pagination, portal, image }
    private struct Sample: Decodable {
        let name: String
        let definitionID: String
        let operation: Operation
        let ruleID: String?
        let pageURL: URL
        let input: String
        let expected: String
        let page: Int?
        let responses: [Response]?
        let keyword: String?
        let resultRuleID: String?
    }
    private struct Response: Decodable { let url: URL; let file: String }
    private struct Fixture { let sample: Sample; let root: URL }

    private func fixtures(_ operation: Operation) throws -> [Fixture] {
        let bundle = Bundle(for: Self.self)
        let roots = ["SiteRegressions", "LocalSiteTests"].compactMap {
            bundle.resourceURL?.appendingPathComponent($0)
        }
        var result: [Fixture] = []
        for root in roots {
            let file = root.appendingPathComponent("cases.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let cases = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: file))
            guard Set(cases.map(\.name)).count == cases.count else {
                throw SiteDefinitionError.invalid("回归样本名称重复")
            }
            result += cases.filter { $0.operation == operation }.map { Fixture(sample: $0, root: root) }
        }
        guard !result.isEmpty else { throw XCTSkip("本次构建没有这类本地回归样本") }
        return result
    }

    private func definitions() throws -> [SiteDefinition] {
        let app = SiteDefinitionStore.bundledDefinitions(bundle: Bundle(for: SiteDefinitionStore.self))
        guard app.issues.isEmpty else { throw SiteDefinitionError.invalid("本地站点配置校验失败") }
        let demo = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        let fixture = try SiteDefinition.decode(String(contentsOf: demo, encoding: .utf8))
        return app.definitions.filter { $0.id != fixture.id } + [fixture]
    }

    private func bytes(_ file: String, fixture: Fixture) throws -> Data {
        try Data(contentsOf: ReaderContainedPath.resolve(file, under: fixture.root))
    }
    private func expected(_ fixture: Fixture) throws -> Any {
        try JSONSerialization.jsonObject(with: bytes(fixture.sample.expected, fixture: fixture), options: .fragmentsAllowed)
    }
    private func owner(_ fixture: Fixture, definitions: [SiteDefinition]) throws -> SiteDefinition {
        try XCTUnwrap(definitions.first { $0.id == fixture.sample.definitionID }, "样本缺少关联的 .site")
    }
    private func rule(_ fixture: Fixture, owner: SiteDefinition) throws -> SiteRule {
        let rule = try XCTUnwrap(owner.rules.first { $0.id == fixture.sample.ruleID }, "样本指定的规则不存在")
        XCTAssertEqual(owner.rule(for: fixture.sample.pageURL, role: rule.role)?.id, rule.id, "页面选中了另一条规则")
        return rule
    }

    /// Dictionaries are field assertions; arrays also pin row count and order.
    private func matches(_ actual: Any, _ expected: Any) -> Bool {
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return false }
            return expected.allSatisfy { key, value in actual[key].map { matches($0, value) } ?? false }
        }
        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any], actual.count == expected.count else { return false }
            return zip(actual, expected).allSatisfy { matches($0.0, $0.1) }
        }
        return (actual as? NSObject)?.isEqual(expected) == true
    }
    private func assertResult(_ actual: Any, fixture: Fixture) throws {
        // Keep private titles, URLs and keys out of assertion diffs.
        XCTAssertTrue(matches(actual, try expected(fixture)), "回归结果不符：\(fixture.sample.name)")
        print("Site regression evaluated: \(fixture.sample.name)")
    }

    func testDefinitionRoundTripsAndReportsFixtureCoverage() throws {
        let values = try definitions()
        let samples = try fixtures(.extract)
        for definition in values {
            XCTAssertTrue(try SiteDefinition.decode(definition.yaml()) == definition, ".site 往返结果不一致")
            let covered = Set(samples.filter { $0.sample.definitionID == definition.id }.compactMap { $0.sample.ruleID })
            let missing = definition.rules.filter { $0.extract != nil && !covered.contains($0.id) }.map(\.id)
            print("Site fixture coverage \(definition.id): extract=\(covered.count), missing=\(missing.joined(separator: ","))")
        }
    }

    func testExtractionSnapshots() async throws {
        let values = try definitions()
        for fixture in try fixtures(.extract) {
            let owner = try owner(fixture, definitions: values)
            let rule = try rule(fixture, owner: owner)
            let page = RegressionPage()
            try await page.load(bytes(fixture.sample.input, fixture: fixture), base: fixture.sample.pageURL)
            try await installResponses(fixture, page: page)
            let extraction = try XCTUnwrap(rule.extract)
            let output = try await WebScript.string(extraction.javascript, in: page.webView)
            let text = try XCTUnwrap(output)
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
            try assertResult(object, fixture: fixture)
        }
    }

    func testPaginationSnapshots() async throws {
        let values = try definitions()
        for fixture in try fixtures(.pagination) {
            let owner = try owner(fixture, definitions: values)
            let rule = try rule(fixture, owner: owner)
            let page = RegressionPage()
            try await page.load(bytes(fixture.sample.input, fixture: fixture), base: fixture.sample.pageURL)
            try await installResponses(fixture, page: page)
            let parser = SiteParserRegistry.parser(definition: owner, rule: rule)
            let value: Any
            switch parser.paginationMode {
            case .webNavigation(let expression):
                value = try await WebScript.evaluate(expression, in: page.webView) ?? NSNull()
            case .ajax(let script, _):
                let raw = try await page.webView.callAsyncJavaScript(script, arguments: ["page": fixture.sample.page ?? 2], in: nil, contentWorld: .page)
                let text = try XCTUnwrap(raw as? String)
                value = try JSONSerialization.jsonObject(with: Data(text.utf8))
            case .none: throw SiteDefinitionError.invalid("分页样本没有对应的分页规则")
            }
            try assertResult(value, fixture: fixture)
            let requests = try await page.webView.callAsyncJavaScript("return window.__fixtureRequests;", arguments: [:], in: nil, contentWorld: .page) as? [String]
            XCTAssertEqual(requests, fixture.sample.responses?.map { $0.url.absoluteString } ?? [], "分页请求地址或次序改变")
        }
    }

    func testSearchSnapshots() async throws {
        let values = try definitions()
        for fixture in try fixtures(.search) {
            let owner = try owner(fixture, definitions: values)
            let sourceRule = try rule(fixture, owner: owner)
            let parser = SiteParserRegistry.parser(definition: owner, rule: sourceRule)
            let keyword = try XCTUnwrap(fixture.sample.keyword)
            let url = try XCTUnwrap(parser.searchURL(keyword: keyword, base: fixture.sample.pageURL), "搜索地址未配置：\(fixture.sample.name)")
            let resultRule = try XCTUnwrap(owner.rule(for: url, role: "catalog"))
            XCTAssertEqual(resultRule.id, fixture.sample.resultRuleID ?? sourceRule.id, "搜索结果选中了另一条规则")
            let page = RegressionPage()
            try await page.load(bytes(fixture.sample.input, fixture: fixture), base: url)
            try await installResponses(fixture, page: page)
            let extracted = try await WebScript.string(try XCTUnwrap(resultRule.extract).javascript, in: page.webView)
            let output = try XCTUnwrap(extracted)
            let items = try JSONSerialization.jsonObject(with: Data(output.utf8))
            let resultParser = SiteParserRegistry.parser(definition: owner, rule: resultRule)
            try assertResult(["url": url.absoluteString, "items": items, "pagination": resultParser.paginationMode.typeString], fixture: fixture)
        }
    }

    private func installResponses(_ fixture: Fixture, page: RegressionPage) async throws {
        var responses: [String: String] = [:]
        for response in fixture.sample.responses ?? [] {
            responses[response.url.absoluteString] = try XCTUnwrap(String(data: bytes(response.file, fixture: fixture), encoding: .utf8))
        }
        _ = try await page.webView.callAsyncJavaScript(#"""
        window.__fixtureRequests = [];
        window.fetch = async function(input) {
            const url = new URL(typeof input === 'string' ? input : input.url, document.baseURI).href;
            window.__fixtureRequests.push(url);
            if (!(url in responses)) throw new Error('Unconfigured offline request');
            return new Response(responses[url], {status: 200});
        };
        """#, arguments: ["responses": responses], in: nil, contentWorld: .page)
    }

    func testPortalSnapshots() throws {
        let values = try definitions()
        for fixture in try fixtures(.portal) {
            let owner = try owner(fixture, definitions: values)
            let config = try XCTUnwrap(owner.portal)
            let portal = try XCTUnwrap(URL(string: config.url))
            let html = try XCTUnwrap(String(data: bytes(fixture.sample.input, fixture: fixture), encoding: .utf8))
            let resolved = SitePortalResolver.resolve(in: html, portal: portal, target: fixture.sample.pageURL, config: config)
            try assertResult(resolved.map { $0.absoluteString as Any } ?? NSNull(), fixture: fixture)
        }
    }

    func testEncryptedCoverSnapshots() async throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let values = try definitions()
        SiteParserRegistry.replaceDefinitions(values)
        for fixture in try fixtures(.image) {
            _ = try owner(fixture, definitions: values)
            let payload = try bytes(fixture.sample.input, fixture: fixture)
            let server = try ImageFixtureServer { _ in payload }
            defer { server.listener.cancel() }
            let request = ThumbnailRequest(url: server.url, referer: fixture.sample.pageURL, definitionID: fixture.sample.definitionID)
            let result = await ImagePipeline.shared.data(for: request)
            let image = try XCTUnwrap(result.flatMap { UIImage(data: $0)?.cgImage }, "封面解码失败：\(fixture.sample.name)")
            try assertResult(["width": image.width, "height": image.height], fixture: fixture)
        }
    }

    func testEncryptedCoverCasesRejectMissingTransform() async throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        var values = try definitions()
        for index in values.indices { values[index].images = nil }
        SiteParserRegistry.replaceDefinitions(values)
        for fixture in try fixtures(.image) {
            let payload = try bytes(fixture.sample.input, fixture: fixture)
            let server = try ImageFixtureServer { _ in payload }
            defer { server.listener.cancel() }
            let result = await ImagePipeline.shared.data(for: server.url, referer: fixture.sample.pageURL, definitionID: fixture.sample.definitionID)
            XCTAssertNil(result, "加密图片缺失站点解码规则时不应通过")
        }
    }
}

@MainActor private final class RegressionPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func load(_ data: Data, base: URL) async throws {
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Keep data-bearing scripts in the DOM, but block page scripts and all network.
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'">"#
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(policy + html, baseURL: base)
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(URLError(.timedOut)))
            }
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
}
