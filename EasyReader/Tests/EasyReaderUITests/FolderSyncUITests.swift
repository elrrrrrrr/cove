import XCTest

@MainActor final class FolderSyncUITests: XCTestCase {
    func testSettingsFolderSyncEntryAndDisconnectedScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let entry = app.buttons["folder-sync-settings"]
        for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(app.navigationBars["文件夹同步"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["folder-sync-choose"].isEnabled)
        XCTAssertTrue(app.staticTexts["尚未连接文件夹"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "文件夹同步-未连接"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["folder-sync-choose"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.navigationBars["文件夹同步"].exists)
    }
}
