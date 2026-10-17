import XCTest

@MainActor final class SiteLoginUITests: XCTestCase {
    func testSettingsLoginPageRetainsDataAndRequiresConfirmationToClear() throws {
        let html = """
        <html><meta name="viewport" content="width=device-width,initial-scale=1"><body>
        <h1>本地登录演示</h1><label>演示账号<input aria-label="演示账号" id="account"></label>
        <button onclick="localStorage.setItem('synthetic-login','yes');document.getElementById('state').textContent='演示登录已保存'">保存演示登录</button><p id="state"></p>
        </body></html>
        """
        let server = try ArticleFixtureServer(routes: ["/": ("text/html; charset=utf-8", Data(html.utf8))])
        defer { server.listener.cancel() }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        for _ in 0..<8 where !management.isHittable { app.swipeUp() }
        management.tap(); app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText("本地登录演示")
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.buttons["保存"].tap()
        let start = app.navigationBars["网站"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let entry = app.buttons["website-login-management"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        for _ in 0..<8 where !entry.isHittable { app.swipeDown() }
        entry.tap()
        app.buttons["website-login-127.0.0.1"].tap()
        XCTAssertTrue(app.staticTexts["默认保留"].exists)
        app.buttons["website-login-open"].tap()
        let input = app.webViews.textFields["演示账号"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("demo")
        app.webViews.buttons["保存演示登录"].tap()
        XCTAssertTrue(app.webViews.staticTexts["演示登录已保存"].waitForExistence(timeout: 5))
        snapshot("website-login-browser", app)
        app.buttons["website-login-done"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 5))
        snapshot("website-login-management", app)
        app.buttons["website-login-clear"].tap()
        XCTAssertTrue(app.buttons["清除并重新登录"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].exists, "Cancelling must retain website data")
        app.buttons["website-login-clear"].tap(); app.buttons["清除并重新登录"].tap()
        XCTAssertTrue(app.staticTexts["暂无记录"].waitForExistence(timeout: 10))
    }
    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
