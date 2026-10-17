import XCTest
@testable import Cove

@MainActor final class PageLoadingPerformanceTests: XCTestCase {
    private func parser(for url: URL, script: String? = nil, ajax: String? = nil) -> SiteParser {
        var definition = SiteDefinition.starter(name: "页面性能夹具", url: url)
        definition.rules[0].load = .init(mode: "auto", waitSeconds: 0)
        definition.rules[0].extract = .init(script: script ?? "return [{title:document.querySelector('h1').textContent,url:'/item'}];")
        if let ajax { definition.rules[0].pagination = .init(mode: "ajax", script: ajax) }
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
    func testVirtualizedFeedViewportOverlapAndExplicitEnd() async throws {
        let server = try ImageFixtureServer { _ in Data("<html><h1>动态列表</h1></html>".utf8) }
        defer { server.listener.cancel() }
        var rule = parser(for: server.url, script: "return [{title:'首页',url:'/one'}];",
            ajax: "if(page>2){window.__more=false;return [];}return [{title:'重复',url:'/one'},{title:'新帖',url:'/two'},{title:'重复新帖',url:'/two'}];")
        rule.hasMoreExpression = "window.__more !== false"
        let loader = PageLoader(); loader.load(url: server.url, parser: rule)
        try await waitUntil { if case .done = loader.state { return true }; return false }
        guard case .done(let initial) = loader.state else { return XCTFail("没有首页") }
        let width = try await loader.webView.evaluateJavaScript("window.innerWidth") as? Int
        let height = try await loader.webView.evaluateJavaScript("window.innerHeight") as? Int
        XCTAssertGreaterThanOrEqual(width ?? 0, 320); XCTAssertGreaterThanOrEqual(height ?? 0, 600)
        loader.loadMore(); try await waitUntil { !loader.isLoadingMore }
        guard case .done(let merged) = loader.state else { return XCTFail("没有分页") }
        XCTAssertEqual(merged.map(\.title), ["首页", "新帖"]); XCTAssertEqual(merged[0].id, initial[0].id)
        loader.loadMore(); try await waitUntil { !loader.isLoadingMore }
        XCTAssertFalse(loader.hasNextPage); XCTAssertFalse(loader.paginationFailed)
        XCTAssertEqual(loader.currentPage, 2)
        guard case .done(let final) = loader.state else { return XCTFail("末页丢失列表") }
        XCTAssertEqual(final, merged)
    }
    func testEmptyPageWithoutEndSignalStillOffersRetry() async throws {
        let server = try ImageFixtureServer { _ in Data("<html><h1>首页</h1></html>".utf8) }
        defer { server.listener.cancel() }
        let loader = PageLoader(); loader.load(url: server.url, parser: parser(for: server.url, ajax: "return [];"))
        try await waitUntil { !loader.state.isActive }
        loader.loadMore(); try await waitUntil { !loader.isLoadingMore }
        XCTAssertTrue(loader.paginationFailed); XCTAssertTrue(loader.hasNextPage)
        guard case .done(let items) = loader.state else { return XCTFail("重试丢失首页") }
        XCTAssertEqual(items.first?.title, "首页")
    }
    func testHasMoreExpressionRoundTripAndValidation() throws {
        var value = SiteDefinition.starter(name: "动态列表", url: URL(string: "https://social.example/profile")!)
        value.rules[0].pagination = .init(mode: "ajax", script: "return [];", hasMoreExpression: "false")
        XCTAssertEqual(try SiteDefinition.decode(value.yaml()), value)
        let parser = SiteParserRegistry.parser(definition: value, rule: value.rules[0])
        XCTAssertEqual(parser.hasMoreExpression, "false")
        XCTAssertEqual(parser.applying(.init(waitSeconds: 1)).hasMoreExpression, "false")
        if case .code = SiteFormSpec.kind("hasMoreExpression", type: "pagination") {} else { XCTFail("Expected JS editor") }
        value.rules[0].pagination?.mode = "none"; XCTAssertThrowsError(try value.validate())
        value.rules[0].pagination?.mode = "ajax"; value.rules[0].pagination?.hasMoreExpression = " "; XCTAssertThrowsError(try value.validate())
    }
}
