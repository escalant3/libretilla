import AppKit
import CartillaDocx
import XCTest

/// Shared set-up for UI tests: a scratch folder, opening copies of fixtures through
/// LaunchServices (which grants the sandbox access), and polling the file on disk.
class CartillaUITestCase: XCTestCase {
    static let bundleID = "app.cartilla.Cartilla"
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var app: XCUIApplication!
    var work: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Start as a fresh install does, outline hidden, whatever an earlier test left: with it open the format
        // bar is narrower and, on a small screen, some of its groups are in the » menu.
        app.launchArguments += ["-CartillaOutlineShown", "NO"]
        // And at the default window size, not a frame some earlier run saved (an empty frame is rejected).
        app.launchArguments += ["-NSWindow Frame CartillaDocumentWindow", ""]
        work = FileManager.default.temporaryDirectory.appendingPathComponent("cartilla-ui-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if app.state != .notRunning { app.terminate() }
        try? FileManager.default.removeItem(at: work)
    }

    func copyFixture(_ name: String, as newName: String) throws -> URL {
        let url = work.appendingPathComponent(newName)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: url)
        return url
    }

    /// Opens `url` in the running app through LaunchServices (which grants the sandbox access).
    @MainActor
    func open(_ url: URL) throws -> XCUIElement {
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first)
        let appURL = try XCTUnwrap(running.bundleURL)
        let done = expectation(description: "opened")
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, _ in done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let name = url.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title CONTAINS %@", name)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "window for \(name)")
        return window
    }

    func text(of url: URL) throws -> String {
        try OOXMLCodec().read(try Data(contentsOf: url)).body.plainText
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return try condition()
    }

    func typeAtStart(_ s: String, in window: XCUIElement) {
        let body = window.textViews["Document body"]
        body.click()
        body.typeKey(.upArrow, modifierFlags: .command)
        body.typeText(s)
    }
}
