import XCTest

@MainActor final class ArticleFeedUITests: XCTestCase {
    func testBentoFeedSaveDetailReturnAndOfflineFavorite() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let image = try Data(contentsOf: root.appendingPathComponent("Articles/article-diagram.png"))
        let html = """
        <main><article class="post"><h2>合成 Feed 一</h2><a href="/post">详情</a><span class="author">演示作者</span>
        <div class="body"><p>第一行正文</p><p>第二行正文</p><img src="/image.png" width="600" height="400"><img src="/image.png?second" width="600" height="400"><blockquote>合成引用内容</blockquote></div></article>
        <article class="post"><h2>合成 Feed 二</h2><a href="/second">详情</a><span class="author">另一位作者</span><div class="body"><p>下一条完整正文</p></div></article></main>
        """
        let server = try ArticleFixtureServer(routes: ["/": ("text/html; charset=utf-8", Data(html.utf8)), "/image.png": ("image/png", image)])
        defer { server.listener.cancel() }
        let yaml = """
        schemaVersion: 1
        id: ui.feed.\(UUID().uuidString)
        name: 合成 Feed
        match: {hosts: [127.0.0.1]}
        entries:
          - {id: main, name: 合成 Feed, path: '\(server.url)', category: news}
        rules:
          - id: feed
            role: catalog
            contentType: article
            presentation: {layout: bento}
            extract:
              items: .post
              fields:
                title: {selector: h2, text: true}
                url: {selector: a, attribute: href}
                article:
                  fields:
                    title: {selector: h2, text: true}
                    author: {selector: .author, text: true}
                    blocks: {selector: .body, content: true}
        """
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["website-management"]
        for _ in 0..<8 where !management.isHittable { app.swipeUp() }
        management.tap(); app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText("合成 Feed")
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let editor = app.textViews["完整站点 YAML"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap(); editor.typeText(yaml)
        app.buttons["保存"].tap()
        let site = app.cells.containing(.staticText, identifier: "合成 Feed").firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5)); site.tap()
        let open = app.buttons.matching(identifier: "article-feed-open").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["第一行正文\n\n第二行正文"].exists)
        snapshot("native-bento-feed", app)
        let save = app.buttons.matching(identifier: "article-feed-save").firstMatch
        save.tap(); XCTAssertEqual(save.label, "已收藏")
        open.tap()
        XCTAssertTrue(app.staticTexts["article-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第一行正文"].exists)
        app.navigationBars["图文阅读"].buttons["BackButton"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "已收藏")
        // Stop the site and restart the app: the saved text must not depend on a live page.
        server.listener.cancel(); app.terminate(); app.launch()
        app.tabBars.buttons["收藏"].tap()
        app.staticTexts["合成 Feed 一"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["第一行正文"].waitForExistence(timeout: 8))
        snapshot("native-saved-feed-offline", app)
    }
    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
