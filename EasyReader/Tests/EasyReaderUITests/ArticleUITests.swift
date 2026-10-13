import XCTest

@MainActor final class ArticleUITests: XCTestCase {
    func testHNListNativeBodyFavoriteHistoryAndOriginalPage() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let fixture = root.appendingPathComponent("Articles")
        let catalog = try Data(contentsOf: fixture.appendingPathComponent("catalog.html"))
        let post = try Data(contentsOf: fixture.appendingPathComponent("post.html"))
        let next = try Data(contentsOf: fixture.appendingPathComponent("next.html"))
        let image = try Data(contentsOf: fixture.appendingPathComponent("article-diagram.png"))
        let server = try ArticleFixtureServer(routes: [
            "/ask":("text/html; charset=utf-8",catalog), "/":("text/html; charset=utf-8",catalog),
            "/ask?p=2":("text/html; charset=utf-8",next), "/?p=2":("text/html; charset=utf-8",next),
            "/item":("text/html; charset=utf-8",post), "/reference":("text/html; charset=utf-8",post),
            "/article-diagram.png":("image/png",image)
        ])
        defer { server.listener.cancel() }
        var yaml = try String(contentsOf: root.appendingPathComponent("examples/sites/hacker-news.site"), encoding: .utf8)
        yaml = yaml.replacingOccurrences(of: "news.ycombinator.com", with: "127.0.0.1")
            .replacingOccurrences(of: "id: example.hackernews", with: "id: ui.hackernews." + UUID().uuidString)
            .replacingOccurrences(of: "name: Ask HN", with: "name: HN 图文演示")
        for path in ["/ask", "/newest", "/show", "/"] {
            yaml = yaml.replacingOccurrences(of: "path: \(path), category:", with: "path: '\(server.url)\(path)', category:")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-readerTheme", "light"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        for _ in 0..<6 where !management.isHittable { app.swipeUp() }
        XCTAssertTrue(management.isHittable); management.tap()
        app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText("HN 图文演示")
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url + "/ask")
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let editor = app.textViews["完整站点 YAML"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap(); editor.typeText(yaml)
        app.buttons["保存"].tap()
        let site = app.cells.containing(.staticText, identifier: "HN 图文演示").firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5)); for _ in 0..<8 where !site.isHittable { app.swipeUp() }; site.tap()
        let title = "Ask HN: 你如何整理每天的阅读？"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 12))
        XCTAssertEqual(app.buttons["browser-layout-menu"].firstMatch.value as? String, "列表")
        XCTAssertTrue(app.staticTexts["第二页：保持内容与展示分离"].waitForExistence(timeout: 8))
        snapshot("hn-native-list", app)
        app.staticTexts[title].tap()
        XCTAssertTrue(app.navigationBars["图文阅读"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["把每天发现的内容放进同一个阅读空间，是我整理资料的第一步。"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["演示评论保留在原网页；不属于原生正文。"].isHittable)
        XCTAssertFalse(app.buttons["全屏播放"].exists)
        snapshot("hn-native-article", app)
        let favoriteButton = app.buttons["article-favorite"]
        if favoriteButton.label == "收藏" { favoriteButton.tap() }
        XCTAssertEqual(favoriteButton.label, "取消收藏")
        app.buttons["图文阅读选项"].tap(); app.buttons["查看原始网页"].tap()
        XCTAssertTrue(app.navigationBars["原始网页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["parsing-live-webview"].exists)
        snapshot("hn-original-article", app)
        app.buttons["返回解析"].tap()
        let bottom = app.staticTexts["article-block-9"]
        for _ in 0..<3 where !bottom.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        XCTAssertTrue(bottom.isHittable, "Native article must scroll to the last paragraph")
        switchTab("收藏", app)
        XCTAssertTrue(app.staticTexts["图文"].waitForExistence(timeout: 5))
        let favorite = app.staticTexts[title].firstMatch
        XCTAssertTrue(favorite.exists); favorite.tap()
        XCTAssertTrue(app.navigationBars["图文阅读"].waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.waitForExistence(timeout: 12))
        XCTAssertTrue(bottom.isHittable, "Returning from favorites or history restores the reading position")
        snapshot("hn-favorite-article", app)
        switchTab("主页", app)
        let recent = app.staticTexts[title].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5)); recent.tap()
        XCTAssertTrue(app.navigationBars["图文阅读"].waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.waitForExistence(timeout: 12))
        XCTAssertTrue(bottom.isHittable, "Returning from favorites or history restores the reading position")
        snapshot("hn-continue-reading", app)
    }

    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func switchTab(_ label: String, _ app: XCUIApplication) {
        let target = app.tabBars.buttons[label]
        for _ in 0..<8 {
            if target.isHittable { target.tap(); return }
            let back = app.navigationBars.firstMatch.buttons["BackButton"]
            if back.isHittable { back.tap() }
            else {
                let start = app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            }
        }
        XCTFail("Could not return to tab \(label)")
    }
}
