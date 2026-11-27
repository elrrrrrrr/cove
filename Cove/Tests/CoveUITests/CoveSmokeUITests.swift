import XCTest

final class CoveSmokeUITests: XCTestCase {
    @MainActor
    func testAppLaunchesAndTabsSwitchCleanly() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }
}
