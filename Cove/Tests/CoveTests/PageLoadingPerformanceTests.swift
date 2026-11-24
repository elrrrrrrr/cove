import XCTest
@testable import Cove

@MainActor final class PageLoadingPerformanceTests: XCTestCase {
    private func parser(for url: URL, script: String? = nil, ajax: String? = nil, nextLinkSelector: String? = nil) -> SiteParser {
        var definition = SiteDefinition.starter(name: "页面性能夹具", url: url)
        definition.rules[0].load = .init(mode: "auto", waitSeconds: 0)
        definition.rules[0].extract = .init(script: script ?? "return [{title:document.querySelector('h1').textContent,url:'/item'}];")
        if let ajax { definition.rules[0].pagination = .init(mode: "ajax", script: ajax) }
        else if let nextLinkSelector { definition.rules[0].pagination = .init(mode: "webNavigation", selector: nextLinkSelector) }
        return SiteParserRegistry.parser(definition: definition, rule: definition.rules[0])
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<240 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("页面没有按预期结束加载")
    }
    func testSupersededHTTPResponseCannotReplaceNewCatalog() async throws {
        let server = try ImageFixtureServer { request in
            if request.contains("GET /old ") { Thread.sleep(forTimeInterval: 0.15) }
            return Data("<html><body><h1>\(request.contains("GET /old ") ? "过期结果" : "当前结果")</h1></body></html>".utf8)
        }
        defer { server.listener.cancel() }
        let old = server.url.deletingLastPathComponent().appendingPathComponent("old"), new = server.url.deletingLastPathComponent().appendingPathComponent("new")
        let loader = PageLoader(), rule = parser(for: old)
        loader.load(url: old, parser: rule)
        try await waitUntil { server.count.value > 0 }
        loader.load(url: new, parser: rule, forceRefresh: true)
        try await waitUntil { if case .done = loader.state { return true }; return false }
        guard case .done(let items) = loader.state else { return XCTFail("缺少解析结果") }
        XCTAssertEqual(items.first?.title, "当前结果"); XCTAssertEqual(loader.currentURL, new)
        try await Task.sleep(for: .milliseconds(200))
        guard case .done(let final) = loader.state else { return XCTFail("解析状态被旧请求覆盖") }
        XCTAssertEqual(final.first?.title, "当前结果")
    }
    func testRefreshWaitsForCompletionAndCanBeCancelled() async throws {
        let server = try ImageFixtureServer { _ in Data("<html><h1>刷新结果</h1></html>".utf8) }
        defer { server.listener.cancel() }
        let loader = PageLoader(); loader.load(url: server.url, parser: parser(for: server.url))
        try await waitUntil { !loader.state.isActive }
        await loader.reloadAsync()
        guard case .done(let items) = loader.state else { return XCTFail("刷新没有等待实际解析完成") }
        XCTAssertEqual(items.first?.title, "刷新结果")
        var returned = false
        let pending = Task { await loader.reloadAsync(); returned = true }
        await Task.yield(); pending.cancel()
        try await waitUntil { returned }
        await pending.value
    }
    func testPaginationLogsStayBoundedAndLateScriptCannotOverwriteReload() async throws {
        let server = try ImageFixtureServer { _ in Data("<html><h1>首页</h1></html>".utf8) }
        defer { server.listener.cancel() }
        let rule = parser(for: server.url, ajax: "await new Promise(resolve => setTimeout(resolve, 400)); return [{title:'旧分页',url:'/old'}];")
        let loader = PageLoader(); loader.load(url: server.url, parser: rule)
        try await waitUntil { !loader.state.isActive }
        loader.loadMore(); try await Task.sleep(for: .milliseconds(50))
        loader.reload(); try await waitUntil { !loader.state.isActive }
        try await Task.sleep(for: .milliseconds(500))
        guard case .done(let items) = loader.state else { return XCTFail("缺少新首页") }
        XCTAssertEqual(items.map(\.title), ["首页"])
        let paginated = parser(for: server.url, ajax: "return [{title:'分页',url:'/item'}];")
        loader.load(url: server.url, parser: paginated, forceRefresh: true)
        try await waitUntil { !loader.state.isActive }
        for _ in 0..<55 { loader.loadMore(); try await waitUntil { !loader.isLoadingMore } }
        XCTAssertLessThanOrEqual(loader.parseLog.count, 200)
        XCTAssertTrue(loader.parseLog.last?.contains("first=") == true || loader.parseLog.last?.contains("last=") == true)
    }
    func testStripResourceTagsPreservesPaginationLinksOnly() {
        let html = """
        <head>
          <link rel="stylesheet" href="/app.css">
          <link rel="next" href="/list/2/">
          <LINK REL='prev' HREF='/list/1/'>
          <script src="/app.js"></script>
        </head>
        """
        let stripped = WebScript.stripResourceTags(html)
        XCTAssertFalse(stripped.contains("stylesheet"))
        XCTAssertFalse(stripped.contains("<script"))
        XCTAssertTrue(stripped.contains(#"rel="next""#))
        XCTAssertTrue(stripped.contains(#"REL='prev'"#))
    }
    func testWebNavigationPaginationLoadsMultiplePagesAndRetriesFailedPage() async throws {
        let page2Attempts = LockedCounter()
        let server = try ImageFixtureServer { request in
            if request.contains("GET /p1 ") {
                return Data(#"<html><head><link rel="stylesheet" href="/bad.css"><link rel="next" href="/p2"></head><body><h1>第1页</h1></body></html>"#.utf8)
            }
            if request.contains("GET /p2 ") {
                if page2Attempts.next() == 1 {
                    return Data("<html><body></body></html>".utf8)
                }
                return Data(#"<html><head><link rel="next" href="/p3"></head><body><h1>第2页</h1></body></html>"#.utf8)
            }
            return Data(#"<html><head><link rel="next" href="/p3"></head><body><h1>第3页</h1></body></html>"#.utf8)
        }
        defer { server.listener.cancel() }
        let base = server.url.deletingLastPathComponent()
        let p1 = base.appendingPathComponent("p1")
        let p2 = base.appendingPathComponent("p2")
        let p3 = base.appendingPathComponent("p3")
        let rule = parser(
            for: p1,
            script: "const h = document.querySelector('h1'); return h ? [{title: h.textContent, url: location.pathname}] : [];",
            nextLinkSelector: #"link[rel="next"]"#
        )
        let loader = PageLoader()
        loader.load(url: p1, parser: rule)
        try await waitUntil { !loader.state.isActive }
        guard case .done(let page1Items) = loader.state else { return XCTFail("缺少第1页") }
        XCTAssertEqual(page1Items.map(\.title), ["第1页"])
        XCTAssertEqual(loader.nextPageURL, p2)
        XCTAssertTrue(loader.canLoadMore)

        // First attempt at page 2 returns empty DOM -> paginationFailed without losing p2 URL
        loader.loadMore()
        try await waitUntil { !loader.isLoadingMore }
        XCTAssertTrue(loader.paginationFailed)
        XCTAssertEqual(loader.nextPageURL, p2)
        XCTAssertEqual(loader.currentPage, 1)

        // Retry loads page 2 and advances nextPageURL to p3
        loader.loadMore()
        try await waitUntil { !loader.isLoadingMore }
        XCTAssertFalse(loader.paginationFailed)
        XCTAssertEqual(loader.currentPage, 2)
        XCTAssertEqual(loader.nextPageURL, p3)
        if case .done(let page2Items) = loader.state {
            XCTAssertEqual(page2Items.map(\.title), ["第1页", "第2页"])
        } else { XCTFail("缺少第2页") }

        // Page 3 self-referencing next link stops pagination cleanly
        loader.loadMore()
        try await waitUntil { !loader.isLoadingMore }
        XCTAssertEqual(loader.currentPage, 3)
        XCTAssertNil(loader.nextPageURL)
        XCTAssertFalse(loader.canLoadMore)
        if case .done(let allItems) = loader.state {
            XCTAssertEqual(allItems.map(\.title), ["第1页", "第2页", "第3页"])
        } else { XCTFail("缺少第3页") }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
