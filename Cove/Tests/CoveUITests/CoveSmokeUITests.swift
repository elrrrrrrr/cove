import XCTest

final class CoveSmokeUITests: XCTestCase {
    @MainActor
    func testAppLaunchesAndTabsSwitchCleanly() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testConfiguredSitesE2E() throws {
        let env = ProcessInfo.processInfo.environment
        guard let screenshotDir = env["E2E_SCREENSHOT_DIR"], !screenshotDir.isEmpty else {
            throw XCTSkip("Set E2E_SCREENSHOT_DIR to run live E2E capture")
        }

        let videoSites = parseSiteList(env["E2E_VIDEO_SITES"])
        let comicSites = parseSiteList(env["E2E_COMIC_SITES"])
        let navSites = parseSiteList(env["E2E_NAV_SITES"])

        let rootURL = URL(fileURLWithPath: screenshotDir, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2.0)
        saveScreenshot(to: rootURL, name: "00_主页")

        for name in videoSites {
            let siteDir = try makeSiteDir(root: rootURL, name: name)
            guard openSite(named: name, in: app) else {
                saveScreenshot(to: siteDir, name: "00_未找到入口")
                continue
            }

            let firstCard = app.descendants(matching: .any)["feed.card.0"].firstMatch
            if !firstCard.waitForExistence(timeout: 22) {
                saveScreenshot(to: siteDir, name: "01_列表页_异常")
                returnHome(in: app)
                continue
            }
            Thread.sleep(forTimeInterval: 4.0)
            saveScreenshot(to: siteDir, name: "01_列表页")

            pullToRefresh(in: app)
            Thread.sleep(forTimeInterval: 5.0)
            saveScreenshot(to: siteDir, name: "02_下拉刷新后")

            let cardToTap = app.descendants(matching: .any)["feed.card.0"].firstMatch
            if cardToTap.waitForExistence(timeout: 5) {
                cardToTap.tap()
                let closePlayer = app.buttons["player.close"].firstMatch
                if closePlayer.waitForExistence(timeout: 20) {
                    Thread.sleep(forTimeInterval: 8.0)
                    saveScreenshot(to: siteDir, name: "03_视频播放页")
                    closePlayer.tap()
                } else {
                    Thread.sleep(forTimeInterval: 3.0)
                    saveScreenshot(to: siteDir, name: "03_视频播放页_回退")
                    let fallbackBack = app.buttons["返回"].firstMatch
                    if fallbackBack.exists && fallbackBack.isHittable { fallbackBack.tap() }
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            returnHome(in: app)
        }

        for name in comicSites {
            let siteDir = try makeSiteDir(root: rootURL, name: name)
            guard openSite(named: name, in: app) else {
                saveScreenshot(to: siteDir, name: "00_未找到入口")
                continue
            }

            let firstCard = app.descendants(matching: .any)["feed.card.0"].firstMatch
            if !firstCard.waitForExistence(timeout: 22) {
                saveScreenshot(to: siteDir, name: "01_列表页_异常")
                returnHome(in: app)
                continue
            }
            Thread.sleep(forTimeInterval: 4.0)
            saveScreenshot(to: siteDir, name: "01_列表页")

            pullToRefresh(in: app)
            Thread.sleep(forTimeInterval: 5.0)
            saveScreenshot(to: siteDir, name: "02_下拉刷新后")

            app.descendants(matching: .any)["feed.card.0"].firstMatch.tap()
            let readBtn = app.buttons["comic.readButton"].firstMatch
            if readBtn.waitForExistence(timeout: 22) {
                Thread.sleep(forTimeInterval: 3.0)
                saveScreenshot(to: siteDir, name: "03_漫画详情页")

                readBtn.tap()
                let readerScroll = app.scrollViews["comic.reader.scroll"].firstMatch
                if readerScroll.waitForExistence(timeout: 22) {
                    Thread.sleep(forTimeInterval: 5.0)
                    saveScreenshot(to: siteDir, name: "04_漫画阅读页")
                    readerScroll.swipeUp()
                    Thread.sleep(forTimeInterval: 2.0)
                    saveScreenshot(to: siteDir, name: "05_漫画阅读页_滚动")
                } else {
                    Thread.sleep(forTimeInterval: 2.0)
                    saveScreenshot(to: siteDir, name: "04_漫画阅读页_异常")
                }

                let closeReader = app.buttons["comic.reader.close"].firstMatch
                if closeReader.exists && closeReader.isHittable {
                    closeReader.tap()
                    Thread.sleep(forTimeInterval: 1.0)
                }
            } else {
                Thread.sleep(forTimeInterval: 2.0)
                saveScreenshot(to: siteDir, name: "03_漫画详情页_异常")
            }

            returnHome(in: app)
        }

        for name in navSites {
            let siteDir = try makeSiteDir(root: rootURL, name: name)
            guard openSite(named: name, in: app) else {
                saveScreenshot(to: siteDir, name: "00_未找到入口")
                continue
            }

            let firstCard = app.descendants(matching: .any)["feed.card.0"].firstMatch
            if !firstCard.waitForExistence(timeout: 22) {
                saveScreenshot(to: siteDir, name: "01_列表页_异常")
                returnHome(in: app)
                continue
            }
            Thread.sleep(forTimeInterval: 4.0)
            saveScreenshot(to: siteDir, name: "01_列表页")

            pullToRefresh(in: app)
            Thread.sleep(forTimeInterval: 5.0)
            saveScreenshot(to: siteDir, name: "02_下拉刷新后")

            let cardToTap = app.descendants(matching: .any)["feed.card.0"].firstMatch
            if cardToTap.waitForExistence(timeout: 5) {
                cardToTap.tap()
                Thread.sleep(forTimeInterval: 6.0)
                saveScreenshot(to: siteDir, name: "03_子页")
            }

            returnHome(in: app)
        }

        Thread.sleep(forTimeInterval: 2.0)
        saveScreenshot(to: rootURL, name: "99_主页_含历史记录")
    }

    private func parseSiteList(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func makeSiteDir(root: URL, name: String) throws -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url = root.appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func saveScreenshot(to dir: URL, name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dest = dir.appendingPathComponent("\(name).png")
        try? png.write(to: dest)
    }

    @MainActor
    private func openSite(named name: String, in app: XCUIApplication) -> Bool {
        let hScroll = app.scrollViews["home.sites.scroll"].firstMatch
        let screen = app.windows.firstMatch.frame
        if hScroll.exists {
            for _ in 0..<2 {
                let s = hScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                let e = hScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                s.press(forDuration: 0.05, thenDragTo: e)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        for attempt in 0..<8 {
            let candidates: [XCUIElement] = [
                app.buttons["home.site.\(name)"].firstMatch,
                app.descendants(matching: .any)["home.site.\(name)"].firstMatch,
                app.staticTexts[name].firstMatch
            ]
            for el in candidates where el.exists {
                let frame = el.frame
                if !frame.isEmpty && frame.midX >= 20 && frame.midX <= screen.width - 20 {
                    el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    return true
                }
            }
            if attempt < 7, hScroll.exists {
                let s = hScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
                let e = hScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
                s.press(forDuration: 0.05, thenDragTo: e)
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        return false
    }

    @MainActor
    private func pullToRefresh(in app: XCUIApplication) {
        let scroll = app.scrollViews["feed.scroll"].firstMatch
        let target = scroll.exists ? scroll : app.scrollViews.firstMatch
        guard target.exists else { return }
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func returnHome(in app: XCUIApplication) {
        for _ in 0..<4 {
            if app.navigationBars["主页"].exists || app.scrollViews["home.sites.scroll"].exists { return }
            let closeReader = app.buttons["comic.reader.close"].firstMatch
            if closeReader.exists && closeReader.isHittable {
                closeReader.tap()
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            let closePlayer = app.buttons["player.close"].firstMatch
            if closePlayer.exists && closePlayer.isHittable {
                closePlayer.tap()
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            let navBack = app.navigationBars.buttons.element(boundBy: 0)
            if navBack.exists && navBack.isHittable {
                navBack.tap()
                Thread.sleep(forTimeInterval: 0.8)
            } else {
                break
            }
        }
    }
}
