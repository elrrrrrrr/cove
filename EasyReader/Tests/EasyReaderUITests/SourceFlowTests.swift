import XCTest

@MainActor final class SourceFlowTests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func expectPlaying(_ app: XCUIApplication) {
        let player = app.descendants(matching: .any)["feed.player"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
        XCTAssertFalse(app.staticTexts["Operation Stopped"].exists)
    }
    private func fill(_ field: XCUIElement, _ value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let old = field.value as? String, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(value)
    }
    private func server() async throws -> (FixtureServer, URL) {
        let html = """
        <html><body>
        <article class="card"><h2 class="title">第一个视频</h2><a href="/watch/1">打开</a><img src="/cover.png"><span class="tag">演员</span></article>
        <article class="card"><h2 class="title">第二个视频</h2><a href="/watch/2">打开</a><img src="/cover.png"></article>
        </body></html>
        """
        let search = #"<article class="card"><h2 class="title">搜索结果</h2><a href="/watch/1">打开</a></article>"#
        let video = #"<html><body><video src="/sample.mp4"></video></body></html>"#
        let bundle = Bundle(for: Self.self)
        let image = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "cover", withExtension: "png", subdirectory: "Media")))
        let movie = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "sample", withExtension: "mp4", subdirectory: "Media")))
        let server = try FixtureServer(routes: [
            "/": FixtureResponse(body: Data(html.utf8)), "/search": FixtureResponse(body: Data(search.utf8)),
            "/watch/1": FixtureResponse(body: Data(video.utf8)), "/watch/2": FixtureResponse(body: Data(video.utf8)),
            "/cover.png": FixtureResponse(mime: "image/png", body: image), "/sample.mp4": FixtureResponse(mime: "video/mp4", body: movie)
        ])
        return (server, try await server.start())
    }
    private func addSource(app: XCUIApplication, name: String, url: URL, feed: Bool) {
        let name = name + "-" + String(UUID().uuidString.prefix(6))
        if app.tabBars.buttons["资源"].exists { app.tabBars.buttons["资源"].tap() }
        else { app.staticTexts["资源"].firstMatch.tap() }
        app.buttons["sources.add"].tap()
        app.buttons["sources.create"].tap()
        fill(app.textFields["名称"], name)
        fill(app.textFields["入口地址"], url.absoluteString)
        app.buttons["模块"].tap()
        fill(app.textFields["标签"], ".tag[]")
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        app.swipeUp()
        let search = app.switches["module.search"]
        for _ in 0..<4 where !search.exists || !search.isHittable { app.swipeUp() }
        if search.value as? String == "0" {
            search.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.textFields["搜索地址，包含 {query}"].waitForExistence(timeout: 5))
        if feed {
            let feed = app.segmentedControls["presentation.open"].buttons["滑动播放"]
            for _ in 0..<4 where !feed.exists || !feed.isHittable { app.swipeUp() }
            XCTAssertTrue(feed.waitForExistence(timeout: 5))
            feed.tap()
        }
        capture("modules", app: app)
        app.navigationBars["添加来源"].buttons["保存"].tap()
        let saved = app.staticTexts[name]
        for _ in 0..<12 where !saved.exists || !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
    }
    func testGuidedSourceCreationAndTagSearchDoesNotOpenPlayer() async throws {
        let (server, url) = try await server(); defer { server.stop() }
        let app = XCUIApplication(); app.launch()
        addSource(app: app, name: "标签验证", url: url, feed: false)
        XCTAssertTrue(app.buttons["演员"].waitForExistence(timeout: 15))
        capture("collection", app: app)
        app.buttons["演员"].tap()
        XCTAssertTrue(app.buttons["搜索结果"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["关闭"].exists)
        capture("search", app: app)
    }
    func testVideoFeedSwipesBetweenItemsAndReturnsToCollection() async throws {
        let (server, url) = try await server(); defer { server.stop() }
        let app = XCUIApplication(); app.launch()
        addSource(app: app, name: "滑动验证", url: url, feed: true)
        let first = app.buttons["第一个视频"]
        XCTAssertTrue(first.waitForExistence(timeout: 15)); first.tap()
        XCTAssertTrue(app.buttons["feed.close"].waitForExistence(timeout: 15))
        expectPlaying(app)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["第二个视频"].waitForExistence(timeout: 10))
        expectPlaying(app)
        capture("feed", app: app)
        app.buttons["feed.close"].tap()
        XCTAssertTrue(app.buttons["第一个视频"].waitForExistence(timeout: 10))
    }
}
