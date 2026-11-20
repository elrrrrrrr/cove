import XCTest
import Network

@MainActor final class SiteSetupUITests: XCTestCase {
    func testManagementShowsCompleteSchemaWithoutLoadingPage() throws {
        let server = try LocalPageServer()
        defer { server.listener.cancel() }
        let app = XCUIApplication()
        let title = "配置查看-" + String(UUID().uuidString.prefix(6))
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        reveal(management, in: app); management.tap()
        app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        replaceCode(yaml, with: """
        schemaVersion: 1
        id: ui.configuration.\(UUID().uuidString)
        name: \(title)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(title)
            path: \(server.url)
            category: video
          - id: books
            name: 配置附加入口
            path: \(server.url)/books
            category: comic
        rules:
          - id: catalog
            role: catalog
            contentType: video
            load:
              mode: auto
              waitSeconds: 0.125
            extract:
              script: |
                return [{title:'配置内容',url:'/watch/1'}];
          - id: detail
            role: video
            extract:
              fields:
                url: {selector: video, attribute: src}
        portal:
          url: https://portal.example/
        images:
          key: '1111111111111111'
          iv: '0000000000000000'
        """, in: app)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        reveal(cell, in: app)
        let requests = server.requestCount.value
        cell.buttons["site-configuration-button"].tap()
        XCTAssertTrue(app.navigationBars["站点配置"].waitForExistence(timeout: 5))
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(yaml.value as? String)
        for field in ["schemaVersion: 1", "entries:", "rules:", "portal:", "images:", "id: detail", "id: books"] {
            XCTAssertTrue(original.contains(field), "Complete configuration must include \(field)")
        }
        XCTAssertEqual(server.requestCount.value, requests, "Viewing configuration must not request the site")

        let renamed = title + " 已编辑"
        replaceCode(yaml, with: original.replacingOccurrences(of: title, with: renamed), in: app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        cell.buttons["site-configuration-button"].tap()
        XCTAssertTrue(app.navigationBars["站点配置"].waitForExistence(timeout: 5))
        XCTAssertEqual(yaml.value as? String, original, "Cancel must preserve the stored configuration")

        let invalid = original + "\nunknownOption: true\n"
        replaceCode(yaml, with: invalid, in: app)
        app.buttons["保存"].tap()
        XCTAssertTrue(yaml.exists, "Invalid source must remain open for repair")
        XCTAssertEqual(yaml.value as? String, invalid)

        replaceCode(yaml, with: original.replacingOccurrences(of: title, with: renamed), in: app)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        let renamedCell = app.cells.containing(.staticText, identifier: renamed).firstMatch
        reveal(renamedCell, in: app)
        renamedCell.buttons["site-configuration-button"].tap()
        XCTAssertTrue(app.navigationBars["站点配置"].waitForExistence(timeout: 5))
        let saved = try XCTUnwrap(yaml.value as? String)
        XCTAssertTrue(saved.contains(renamed))
        XCTAssertTrue(saved.contains("portal:")); XCTAssertTrue(saved.contains("images:"))
        XCTAssertEqual(server.requestCount.value, requests)
    }

    func testCreateCSSConfigurationAndEditCustomJavaScript() throws {
        let app = XCUIApplication()
        let title = "测试配置-" + String(UUID().uuidString.prefix(6))
        let siteID = "ui.script." + UUID().uuidString.lowercased()
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        reveal(management, in: app)
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        management.tap()
        app.buttons["添加或导入站点"].tap()
        app.buttons["创建站点规则"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        let starter = try XCTUnwrap(yaml.value as? String)
        XCTAssertTrue(starter.contains("selector:"))
        replaceCode(yaml, with: """
        schemaVersion: 1
        id: \(siteID)
        name: \(title)
        match:
          hosts: [media.example]
        entries:
          - id: main
            name: \(title)
            path: https://media.example/latest/
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            extract:
              items: .card
              fields:
                title: {selector: .title, text: true}
                url: {selector: a, attribute: href}
        """, in: app)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        reveal(cell, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.swipeRight()
        app.buttons["解析规则"].tap()
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        replaceCode(yaml, with: """
        schemaVersion: 1
        id: \(siteID)
        name: \(title)
        match:
          hosts: [media.example]
        entries:
          - id: main
            name: \(title)
            path: https://media.example/latest/
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            extract:
              script: |
                return [{title:'自定义内容',url:'https://media.example/watch/1'}];
        """, in: app)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["网站"].waitForExistence(timeout: 5))
        reveal(cell, in: app)
        cell.swipeRight()
        app.buttons["解析规则"].tap()
        let persisted = try XCTUnwrap(app.textViews["完整站点 YAML"].value as? String)
        XCTAssertTrue(persisted.contains("自定义内容"))
        XCTAssertTrue(persisted.contains("script:"))
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
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        replaceCode(yaml, with: """
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
        """, in: app)
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
        search.buttons.firstMatch.tap()
        let gallery = app.navigationBars[title]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        for layout in ["列表", "竖版", "Bento"] {
            let requests = server.requestCount.value
            let menu = app.buttons["browser-layout-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
            app.buttons[layout].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "交互视频").firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(server.requestCount.value, requests, "Layout switching must reuse loaded items")
            if layout != "列表" {
                let actor = app.buttons["交互标签"]
                XCTAssertTrue(actor.waitForExistence(timeout: 3)); actor.tap()
                XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertTrue(search.isHittable)
                search.buttons.firstMatch.tap()
                XCTAssertTrue(gallery.waitForExistence(timeout: 5))
            }
        }
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
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5))
        replaceCode(yaml, with: """
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
        """, in: app)
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

    private func replaceCode(_ editor: XCUIElement, with text: String, in app: XCUIApplication) {
        editor.tap(); editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap(); editor.typeText(text)
    }

    private func reveal(_ cell: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if cell.isHittable { return }
            app.swipeUp()
        }
    }
}

final class LocalPageServer {
    let listener: NWListener
    let requestCount = RequestCounter()
    let url: String
    init(body: String = "<html><body>Offline fixture</body></html>", image: Data? = nil) throws {
        let ready = DispatchSemaphore(value: 0)
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "CoveUITestHTTP")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let counter = requestCount
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { request, _, _, _ in
                counter.increment()
                let isImage = String(data: request ?? Data(), encoding: .utf8)?.contains("GET /cover.png ") == true && image != nil
                let bytes = isImage ? image! : Data(body.utf8)
                let type = isImage ? "image/png" : "text/html; charset=utf-8"
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
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

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
