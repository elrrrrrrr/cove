import XCTest

@MainActor final class SiteSearchUITests: XCTestCase {
    func testSearchUsesItsOwnComicRuleAndCancelRestoresCategory() throws {
        let server = try LocalPageServer(body: """
        <html><head><meta charset="utf-8"><title>搜索夹具</title></head><body>
        <article class="home-card"><a href="/book/1">分类中的漫画</a></article>
        <article class="search-card"><a href="/book/2">搜索到的漫画</a></article>
        <h1>离线漫画详情</h1><a class="chapter" href="/chapter/1">离线第一章</a>
        </body></html>
        """)
        defer { server.listener.cancel() }
        let app = XCUIApplication(), name = "漫画搜索-" + String(UUID().uuidString.prefix(6))
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        for _ in 0..<6 { if management.isHittable { break }; app.swipeUp() }
        management.tap(); app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText(name)
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let editor = app.textViews["完整站点 YAML"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        editor.typeText("""
        schemaVersion: 1
        id: ui.search.\(UUID().uuidString)
        name: \(name)
        match: {hosts: [127.0.0.1]}
        entries:
          - {id: main, name: \(name), path: '\(server.url)', category: comic}
        rules:
          - id: catalog
            role: catalog
            contentType: comic
            presentation: {layout: portrait}
            searchURLTemplate: /search?q={keyword}
            extract:
              items: .home-card
              fields:
                title: {selector: a, text: true}
                url: {selector: a, attribute: href}
          - id: search
            role: catalog
            match: {pathPrefix: /search}
            contentType: comic
            presentation: {layout: list}
            pagination: {mode: none}
            searchURLTemplate: /search?q={keyword}
            extract:
              items: .search-card
              fields:
                title: {selector: a, text: true}
                url: {selector: a, attribute: href}
          - id: detail
            role: comic
            extract:
              fields:
                title: {selector: h1, text: true}
                chapters:
                  selector: .chapter
                  all: true
                  fields:
                    title: {text: true}
                    url: {attribute: href}
        """)
        app.buttons["保存"].tap()
        let site = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        for _ in 0..<6 { if site.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(site.isHittable); site.tap()
        XCTAssertTrue(app.staticTexts["分类中的漫画"].waitForExistence(timeout: 10))
        submit("漫画", in: app)
        XCTAssertTrue(app.staticTexts["搜索到的漫画"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["分类中的漫画"].exists)
        snapshot("comic-search-results", app: app)
        let clear = app.searchFields.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", ["Clear text", "清除文本"])).firstMatch
        XCTAssertTrue(clear.exists); clear.tap()
        let cancel = ["Close", "Cancel", "关闭", "取消"].map { app.navigationBars[name].buttons[$0] }.first { $0.exists }
        XCTAssertNotNil(cancel)
        try XCTUnwrap(cancel).tap()
        XCTAssertTrue(app.staticTexts["分类中的漫画"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["搜索到的漫画"].exists)
        XCTAssertEqual(app.buttons["browser-layout-menu"].firstMatch.value as? String, "竖版")
        snapshot("comic-category-after-cancel", app: app)
        submit("漫画", in: app)
        let result = app.staticTexts["搜索到的漫画"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(app.staticTexts["离线第一章"].waitForExistence(timeout: 10), "Search results must open the comic reader's detail route")
        XCTAssertFalse(app.buttons["全屏播放"].exists)
        snapshot("comic-search-detail", app: app)
    }

    private func submit(_ keyword: String, in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(keyword + "\n")
    }
    private func snapshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
