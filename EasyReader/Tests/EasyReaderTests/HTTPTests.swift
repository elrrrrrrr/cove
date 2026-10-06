import XCTest
@testable import EasyReader

final class HTTPTests: XCTestCase {
    func testDownloadRejectsHTTP404AndOversizedDeclaredResponse() async throws {
        let server = try FixtureServer(routes: [
            "/missing": FixtureResponse(status: 404, body: Data("missing".utf8)),
            "/oversize": FixtureResponse(body: Data(repeating: 1, count: 10_000), declaredLength: 1_000_000)
        ])
        let base = try await server.start()
        defer { server.stop() }
        do { _ = try await BoundedDownloader.download(URLRequest(url: base.appendingPathComponent("missing")), maxBytes: 100); XCTFail("Expected 404 failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
        do { _ = try await BoundedDownloader.download(URLRequest(url: base.appendingPathComponent("oversize")), maxBytes: 100); XCTFail("Expected size failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("容量")) }
    }
    func testDownloadPublishesUniqueFilesAndSupportsCancellation() async throws {
        let server = try FixtureServer(routes: ["/file": FixtureResponse(body: Data("valid".utf8))])
        let base = try await server.start()
        defer { server.stop() }
        let first = try await BoundedDownloader.download(URLRequest(url: base.appendingPathComponent("file")), maxBytes: 100)
        let second = try await BoundedDownloader.download(URLRequest(url: base.appendingPathComponent("file")), maxBytes: 100)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("valid".utf8))
        try FileManager.default.removeItem(at: first); try FileManager.default.removeItem(at: second)
        let cancelled = Task { try await BoundedDownloader.download(URLRequest(url: base.appendingPathComponent("file")), maxBytes: 100) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    @MainActor func testWebProviderParsesListsSearchAndNextLinkWithSharedSession() async throws {
        let html = #"<article class="card"><h2 class="title">第一项</h2><a href="/watch/1">打开</a><span class="tag">演员</span></article><a rel="next" href="/next">下一页</a>"#
        let next = #"<article class="card"><h2 class="title">第二项</h2><a href="/watch/2">打开</a></article>"#
        let server = try FixtureServer(routes: [
            "/": FixtureResponse(body: Data(html.utf8)), "/next": FixtureResponse(body: Data(next.utf8)),
            "/search": FixtureResponse(body: Data(next.utf8))
        ])
        let base = try await server.start(); defer { server.stop() }
        var definition = SourceDefinition.starter(name: "测试", adapter: .web, url: base.absoluteString)
        definition.modules?.pagination = PaginationModule(next: SelectorField(shorthand: "a[rel=next]@href"))
        definition.modules?.search = SearchModule(url: "/search?q={query}")
        let provider = WebSourceProvider(definition: definition); defer { provider.close() }
        let first = try await provider.list(CollectionRequest(locator: base.absoluteString, forceRefresh: true))
        XCTAssertEqual(first.items.first?.title, "第一项")
        let nextCursor = try XCTUnwrap(first.nextCursor)
        let second = try await provider.list(CollectionRequest(locator: base.absoluteString, cursor: nextCursor, forceRefresh: true))
        XCTAssertEqual(second.items.first?.title, "第二项")
        XCTAssertNil(second.nextCursor)
        let search = try await provider.list(CollectionRequest(locator: base.absoluteString, query: "猫&foo=bar", forceRefresh: true))
        XCTAssertEqual(search.items.first?.title, "第二项")
    }
}
