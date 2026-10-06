import XCTest

@MainActor final class SiteSetupUITests: XCTestCase {
    func testCreateCSSConfigurationAndEditCustomJavaScript() throws {
        let app = XCUIApplication()
        let title = "测试配置-" + String(UUID().uuidString.prefix(6))
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["管理网站"].tap()
        app.buttons["添加或导入站点"].tap()
        app.buttons["创建站点规则"].tap()
        let name = app.textFields["站点名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(title)
        let address = app.textFields["入口 URL"]
        address.tap()
        address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        address.typeText("https://media.example/latest/")
        app.buttons["创建配置并打开页面"].tap()
        app.segmentedControls.buttons["高级"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        let cssText = try XCTUnwrap(yaml.value as? String)
        XCTAssertTrue(cssText.contains("selector:"))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        reveal(cell, in: app)
        cell.swipeRight()
        app.buttons["解析规则"].tap()
        app.segmentedControls.buttons["高级"].tap()
        app.segmentedControls.buttons["JavaScript"].tap()
        app.buttons["清空脚本"].tap()
        let script = app.textViews["自定义 JavaScript"]
        script.tap()
        script.typeText("return [{title:'自定义内容',url:'https://media.example/watch/1'}];")
        XCTAssertTrue((script.value as? String)?.contains("自定义内容") == true)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        reveal(cell, in: app)
        cell.swipeRight()
        app.buttons["解析规则"].tap()
        app.segmentedControls.buttons["高级"].tap()
        let persisted = try XCTUnwrap(app.textViews["完整站点 YAML"].value as? String)
        XCTAssertTrue(persisted.contains("自定义内容"))
        XCTAssertTrue(persisted.contains("script:"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    private func reveal(_ cell: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if cell.isHittable { return }
            app.swipeUp()
        }
    }
}
