import XCTest

@MainActor final class ParsingWebViewUITests: XCTestCase {
    func testInspectSlowGalleryAndVideoWithoutReloadingTheirLivePages() throws {
        let server = try LocalPageServer(body: """
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>诊断夹具页面</title></head>
        <body><h1>当前真实页面</h1><button onclick="document.getElementById('marker').textContent='现场标记已保留'">设置现场标记</button><p id="marker">尚未设置标记</p></body></html>
        """)
        defer { server.listener.cancel() }
        let app = XCUIApplication(), name = "网页现场-" + String(UUID().uuidString.prefix(6))
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        for _ in 0..<6 { if management.isHittable { break }; app.swipeUp() }
        management.tap(); app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText(name)
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5)); yaml.tap(); yaml.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        yaml.typeText("""
        schemaVersion: 1
        id: ui.inspect.\(UUID().uuidString)
        name: \(name)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(name)
            path: \(server.url)
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            load: {mode: webView, waitSeconds: 30}
            extract:
              script: "return [{title:'诊断测试视频',url:'/watch/1'}];"
          - id: video
            role: video
            load: {mode: webView, waitSeconds: 30}
            extract:
              script: "return null;"
        """)
        app.buttons["保存"].tap()
        let site = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5)); site.tap()
        let inspect = app.buttons["inspect-current-webpage"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 5)); inspect.tap()
        XCTAssertTrue(app.navigationBars["原始网页"].waitForExistence(timeout: 5))
        let realPage = app.webViews.staticTexts["当前真实页面"]
        XCTAssertTrue(realPage.waitForExistence(timeout: 10))
        let requests = server.requestCount.value
        app.webViews.buttons["设置现场标记"].tap()
        XCTAssertTrue(app.webViews.staticTexts["现场标记已保留"].waitForExistence(timeout: 5))
        snapshot("gallery-live-webview", app: app)
        app.buttons["返回解析"].tap()
        app.buttons["站点工具"].tap(); app.buttons["inspect-current-webpage-menu"].tap()
        XCTAssertTrue(app.webViews.staticTexts["现场标记已保留"].waitForExistence(timeout: 5))
        XCTAssertEqual(server.requestCount.value, requests, "Inspect and return must reuse the same document")
        app.buttons["网页查看选项"].tap(); app.buttons["重新打开完整原网页"].tap()
        XCTAssertTrue(app.webViews.staticTexts["尚未设置标记"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(server.requestCount.value, requests, "Full page explicitly performs a fresh navigation")
        app.buttons["网页查看选项"].tap(); app.buttons["查看解析中的页面"].tap()
        XCTAssertTrue(app.webViews.staticTexts["现场标记已保留"].waitForExistence(timeout: 5))
        app.buttons["返回解析"].tap()
        let video = app.staticTexts["诊断测试视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 45), "Parsing must finish after inspection closes")
        video.tap()
        XCTAssertTrue(inspect.waitForExistence(timeout: 5))
        snapshot("video-loading-inspection-action", app: app)
        inspect.tap()
        XCTAssertTrue(realPage.waitForExistence(timeout: 10))
        let videoRequests = server.requestCount.value
        app.webViews.buttons["设置现场标记"].tap()
        snapshot("video-live-webview", app: app)
        app.buttons["返回解析"].tap(); inspect.tap()
        XCTAssertTrue(app.webViews.staticTexts["现场标记已保留"].waitForExistence(timeout: 5))
        XCTAssertEqual(server.requestCount.value, videoRequests, "Video inspection must not restart extraction")
        app.buttons["返回解析"].tap(); app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
    }
    private func snapshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
