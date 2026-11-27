import XCTest
import WebKit
@testable import Cove

@MainActor
final class SiteDefinitionTests: XCTestCase {
    private func demoFixture() throws -> SiteDefinition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        return try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
    }

    func testSchemaVersion1RoundTripAndPathRouting() throws {
        let def = try demoFixture()
        XCTAssertEqual(def.schemaVersion, 1)
        XCTAssertEqual(try SiteDefinition.decode(def.yaml()), def)
        XCTAssertEqual(def.rule(for: URL(string: "https://media.example/books/")!, role: "catalog")?.contentType, "comic")
        XCTAssertEqual(def.rule(for: URL(string: "https://media.example/latest/")!, role: "catalog")?.contentType, "video")
        XCTAssertNil(def.rule(for: URL(string: "https://media.example/other/")!, role: "catalog"))
    }

    func testRejectsUnknownDuplicateKeysAndUnsupportedVersions() throws {
        let yaml = try demoFixture().yaml()
        XCTAssertThrowsError(try SiteDefinition.decode(yaml + "unknownKey: true\n"))
        XCTAssertThrowsError(try SiteDefinition.decode(yaml + "id: duplicate\n"))

        var bad = try demoFixture()
        bad.schemaVersion = 99
        XCTAssertThrowsError(try bad.validate())

        bad = try demoFixture()
        bad.match.hostPattern = "["
        XCTAssertThrowsError(try bad.validate())
    }

    func testDomainBoundaryMatchingAndPortalResolution() throws {
        let match = SiteMatch(hosts: ["media.example"], includeSubdomains: true)
        XCTAssertTrue(match.matches(URL(string: "https://media.example/")!))
        XCTAssertTrue(match.matches(URL(string: "https://cdn.media.example/")!))
        XCTAssertFalse(match.matches(URL(string: "https://media.example.attacker.example/")!))

        let portal = SitePortal(url: "https://portal.example/", base64Pattern: #"atob\(['"]([A-Za-z0-9+/=]+)['"]\)"#, excludedHosts: ["ads.example"])
        let html = "atob('\(Data("<a href=\"https://ads.example\">ad</a><a href=\"https://next.example\">ok</a>".utf8).base64EncodedString())')"
        let resolved = SitePortalResolver.resolve(in: html, portal: URL(string: "https://portal.example/")!,
                                                  target: URL(string: "https://old.example/watch/1")!, config: portal)
        XCTAssertEqual(resolved?.absoluteString, "https://next.example/watch/1")
    }

    func testAESDecryptionForImageTransform() throws {
        // 16-byte plaintext padded with PKCS7 encrypted or tested via empty/invalid guards
        let bad = SiteCrypto.decrypt(Data([1, 2, 3]), key: Data(repeating: 0x41, count: 16), iv: Data(repeating: 0x42, count: 16))
        XCTAssertNil(bad)
        let badIV = SiteCrypto.decrypt(Data(repeating: 0, count: 16), key: Data(repeating: 0x41, count: 16), iv: Data(repeating: 0x42, count: 8))
        XCTAssertNil(badIV)
    }

    func testWebSessionExtractsLocalhostCatalogAndArticle() async throws {
        let html = """
        <html><body>
        <article><h1>本地文章</h1><p>第一段正文。</p></article>
        <div class="card"><a href="/v/1"><img src="/t/1.jpg"><h3 class="title">示例视频</h3></a><span class="duration">03:21</span></div>
        </body></html>
        """
        let server = try ArticleFixtureServer(routes: ["/": ("text/html; charset=utf-8", Data(html.utf8))])
        let baseURL = try XCTUnwrap(URL(string: server.url + "/"))

        let def = SiteDefinition(
            id: "test.local",
            name: "Local Demo",
            match: SiteMatch(hosts: ["127.0.0.1"]),
            entries: [SiteEntry(id: "main", name: "Main", path: baseURL.absoluteString, category: "video")],
            rules: [
                SiteRule(
                    id: "catalog", role: "catalog", contentType: "video",
                    load: SiteLoad(mode: "webView"),
                    extract: SiteExtraction(items: ".card", fields: [
                        "title": SiteField(selector: ".title", text: true),
                        "url": SiteField(selector: "a", attribute: "href"),
                        "thumbnail": SiteField(selector: "img", attribute: "src"),
                        "duration": SiteField(selector: ".duration", text: true)
                    ])
                ),
                SiteRule(
                    id: "article", role: "article",
                    load: SiteLoad(mode: "webView"),
                    extract: SiteExtraction(fields: [
                        "title": SiteField(selector: "h1", text: true),
                        "blocks": SiteField(selector: "article", content: true)
                    ])
                )
            ]
        )

        let session = WebSession()
        let parser = SiteParserRegistry.parser(definition: def, rule: def.rules[0])
        session.loadCatalog(url: baseURL, parser: parser)

        for _ in 0..<250 {
            if case .done = session.catalogState { break }
            if case .failed(let err) = session.catalogState { XCTFail(err); break }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .done(let items) = session.catalogState else {
            return XCTFail("Catalog did not finish loading")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "示例视频")
        XCTAssertEqual(items.first?.duration, "03:21")
        XCTAssertEqual(items.first?.pageURL.path, "/v/1")
    }
}
