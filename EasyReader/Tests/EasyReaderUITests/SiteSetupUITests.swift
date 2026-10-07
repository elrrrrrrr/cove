import XCTest
import Network

@MainActor final class SiteSetupUITests: XCTestCase {
    func testCreateCSSConfigurationAndEditCustomJavaScript() throws {
        let app = XCUIApplication()
        let title = "测试配置-" + String(UUID().uuidString.prefix(6))
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        reveal(management, in: app)
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        management.tap()
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
        reveal(cell, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
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
    func testVideoTagSearchDoesNotAlsoPresentPlayer() throws {
        let server = try LocalPageServer()
        defer { server.listener.cancel() }
        let app = XCUIApplication()
        let title = "标签交互-" + String(UUID().uuidString.prefix(6))
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        reveal(management, in: app)
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        management.tap()
        app.buttons["添加或导入站点"].tap()
        app.buttons["创建站点规则"].tap()
        let name = app.textFields["站点名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(title)
        let address = app.textFields["入口 URL"]
        address.tap()
        address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap()
        app.segmentedControls.buttons["高级"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        yaml.tap(); yaml.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
        selectAll.tap()
        yaml.typeText("""
        schemaVersion: 1
        id: ui.tags.\(UUID().uuidString)
        name: \(title)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(title)
            path: \(server.url)
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            searchURLTemplate: '?q={keyword}'
            extract:
              script: |
                return [{title:'交互视频',url:'/watch/1',extra:'交互标签'}];
        """)
        app.buttons["保存"].tap()
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        reveal(cell, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()
        let tag = app.descendants(matching: .any).matching(identifier: "交互标签").firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 10))
        tag.tap()
        let search = app.navigationBars["交互标签"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable, "Tag search must remain visible without a player covering it")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        search.buttons.firstMatch.tap()
        let gallery = app.navigationBars[title]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        let requests = server.requestCount.value
        for layout in ["列表", "竖版", "Bento"] {
            let menu = app.buttons["browser-layout-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
            app.buttons[layout].tap()
            XCTAssertTrue(app.staticTexts["交互视频"].waitForExistence(timeout: 3))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "web-" + layout; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(server.requestCount.value, requests, "Layout switching must reuse loaded items")
        app.staticTexts["交互视频"].tap()
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: gallery)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 5), .completed, "Card tap must still present playback")
    }

    func testBentoDirectoryNavigationAndLayoutPersistence() throws {
        let server = try LocalPageServer()
        defer { server.listener.cancel() }
        let app = XCUIApplication()
        let title = "目录布局-" + String(UUID().uuidString.prefix(6))
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        reveal(management, in: app); management.tap()
        app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        let name = app.textFields["站点名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5)); yaml.tap(); yaml.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        yaml.typeText("""
        schemaVersion: 1
        id: ui.directories.\(UUID().uuidString)
        name: \(title)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(title)
            path: \(server.url)
            category: other
        rules:
          - id: catalog
            role: catalog
            contentType: navLink
            extract:
              script: |
                return [{title:'子目录',url:'/sub'}];
        """)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        reveal(cell, in: app); cell.tap()
        XCTAssertTrue(app.staticTexts["子目录"].waitForExistence(timeout: 10))
        app.buttons["browser-layout-menu"].tap(); app.buttons["Bento"].tap()
        app.staticTexts["子目录"].tap()
        XCTAssertTrue(app.navigationBars["子目录"].waitForExistence(timeout: 5), "Directory cards must navigate, regardless of layout")
        app.navigationBars["子目录"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["browser-layout-menu"].value as? String, "Bento")
        app.terminate(); app.launch(); app.tabBars.buttons["设置"].tap()
        reveal(management, in: app); management.tap(); reveal(cell, in: app); cell.tap()
        XCTAssertTrue(app.buttons["browser-layout-menu"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["browser-layout-menu"].value as? String, "Bento")
    }

    private func reveal(_ cell: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if cell.isHittable { return }
            app.swipeUp()
        }
    }
}

private final class LocalPageServer {
    let listener: NWListener
    let requestCount = RequestCounter()
    let url: String
    init() throws {
        let ready = DispatchSemaphore(value: 0)
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "CoveUITestHTTP")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let counter = requestCount
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                counter.increment()
                let body = "<html><body>Offline fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "LocalPageServer", code: 1)
        }
        url = "http://127.0.0.1:\(port.rawValue)/"
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
