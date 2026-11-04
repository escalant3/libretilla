import XCTest

final class LaunchSmokeTests: XCTestCase {
    @MainActor
    func testLaunchShowsUntitledDocumentWindow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Document body"].exists)
        app.terminate()
    }
}
