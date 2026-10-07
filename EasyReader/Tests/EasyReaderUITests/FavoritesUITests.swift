import XCTest

@MainActor final class FavoritesUITests: XCTestCase {
    func testPinManagementReorderingAndRestartKeepFavoritesAndSearch() throws {
        let server = try LocalPageServer()
        defer { server.listener.cancel() }
        let app = XCUIApplication()
        let prefix = "置顶测试-" + String(UUID().uuidString.prefix(6))
        let names = ["甲", "乙", "丙"].map { prefix + $0 }
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]
        for _ in 0..<6 { if management.isHittable { break }; app.swipeUp() }
        management.tap(); app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        app.textFields["站点名称"].tap(); app.textFields["站点名称"].typeText(prefix)
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let yaml = app.textViews["完整站点 YAML"]
        XCTAssertTrue(yaml.waitForExistence(timeout: 5)); yaml.tap(); yaml.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        yaml.typeText("""
        schemaVersion: 1
        id: ui.pins.\(UUID().uuidString)
        name: \(prefix)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(prefix)
            path: \(server.url)
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            presentation: {layout: list}
            extract:
              script: |
                return [{title:'\(names[0])',url:'/watch/1'},{title:'\(names[1])',url:'/watch/2'},{title:'\(names[2])',url:'/watch/3'}];
        """)
        app.buttons["保存"].tap()
        let site = app.cells.containing(.staticText, identifier: prefix).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5)); site.tap()
        for name in names {
            let card = app.staticTexts[name]
            XCTAssertTrue(card.waitForExistence(timeout: 10)); card.press(forDuration: 1)
            let menuAction = app.buttons.matching(identifier: "收藏").allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minY < app.tabBars.firstMatch.frame.minY
            }
            try XCTUnwrap(menuAction).tap()
        }
        app.navigationBars[prefix].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        enterFavorites(in: app)
        let a = app.buttons[names[0]], b = app.buttons[names[1]], c = app.buttons[names[2]]
        for card in [a, b, c] { XCTAssertTrue(card.waitForExistence(timeout: 5)) }
        a.press(forDuration: 1); app.buttons["置顶"].tap()
        XCTAssertEqual(a.value as? String, "已置顶")
        openManager(in: app)
        app.buttons["置顶" + names[1]].tap()
        let first = app.cells.containing(.staticText, identifier: names[0]).firstMatch
        let second = app.cells.containing(.staticText, identifier: names[1]).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).press(forDuration: 0.7,
            thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.1)))
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in first.frame.minY > second.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        snapshot("manual-pin-order", app: app)
        app.buttons["完成"].tap()
        XCTAssertEqual(a.value as? String, "已置顶"); XCTAssertEqual(b.value as? String, "已置顶")
        XCTAssertGreaterThan(a.frame.minY, b.frame.minY)
        snapshot("favorites-pinned-section", app: app)
        app.terminate(); app.launch(); enterFavorites(in: app)
        XCTAssertTrue(a.waitForExistence(timeout: 5)); XCTAssertGreaterThan(a.frame.minY, b.frame.minY)
        a.press(forDuration: 1); app.buttons["取消置顶"].tap()
        XCTAssertNotEqual(a.value as? String, "已置顶")
        openManager(in: app)
        XCTAssertTrue(app.buttons["置顶" + names[0]].waitForExistence(timeout: 5), "Unpin must retain the favorite")
        XCTAssertTrue(app.buttons["取消置顶" + names[1]].exists)
        app.buttons["完成"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(names[0])
        XCTAssertTrue(a.waitForExistence(timeout: 5)); XCTAssertFalse(b.exists)
    }

    private func openManager(in app: XCUIApplication) {
        app.buttons["收藏工具"].tap(); app.buttons["管理置顶"].tap()
        XCTAssertTrue(app.navigationBars["管理置顶"].waitForExistence(timeout: 5))
    }
    private func enterFavorites(in app: XCUIApplication) {
        app.tabBars.buttons["收藏"].tap()
        if !app.navigationBars["收藏"].waitForExistence(timeout: 3) { app.tabBars.buttons["收藏"].tap() }
        XCTAssertTrue(app.navigationBars["收藏"].waitForExistence(timeout: 5))
    }
    private func snapshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
