import AppKit
import XCTest

/// View zoom with real key events, as in Google Docs: ⌘+ / ⌘= / ⌘− / ⌘0 zoom the page (the format bar's
/// zoom menu follows), and ⇧⌘> / ⇧⌘< change the font size instead.
final class ZoomUITests: LibretillaUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every run starts at 100% whatever an earlier run left behind.
        app.launchArguments += ["-LibretillaZoom", "1"]
    }

    func shoot(_ window: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testZoomShortcutsAndMenu() throws {
        let file = try copyFixture("02-headings.docx", as: "Zoom.docx")
        app.launch()
        let window = try open(file)
        let body = window.textViews["Document body"]
        body.click()
        let zoom = window.popUpButtons["Zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "format bar zoom menu")
        func zoomValue() -> String { zoom.value as? String ?? "" }
        XCTAssertEqual(zoomValue(), "100%")
        shoot(window, "1-zoom-100")

        body.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "125%" }, "⌘= zooms in; got \(zoomValue())")
        body.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "150%" }, "⌘+ zooms in; got \(zoomValue())")
        body.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "200%" }, "got \(zoomValue())")
        shoot(window, "2-zoom-200")
        body.typeKey("r", modifierFlags: .command)
        shoot(window, "3-zoom-200-ruler")
        body.typeKey("r", modifierFlags: .command)

        body.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "100%" }, "⌘0 resets; got \(zoomValue())")
        body.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "90%" }, "⌘− zooms out; got \(zoomValue())")
        body.typeKey("-", modifierFlags: .command)
        body.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "50%" }, "got \(zoomValue())")
        shoot(window, "4-zoom-50")
        body.typeKey("-", modifierFlags: .command)
        XCTAssertEqual(zoomValue(), "50%", "50% is the least")

        // The format bar's menu.
        zoom.click()
        window.menuItems["150%"].click()
        XCTAssertTrue(waitUntil(3) { zoomValue() == "150%" }, "got \(zoomValue())")
        shoot(window, "5-zoom-150-menu")
        body.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "100%" })

        // Fit, from the format bar's menu: the page takes the window's width; a step leaves it.
        zoom.click()
        window.menuItems["Fit"].click()
        XCTAssertTrue(waitUntil(3) { zoomValue() == "Fit" }, "got \(zoomValue())")
        shoot(window, "6-zoom-fit")
        body.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(waitUntil(3) { zoomValue() == "100%" }, "⌘0 leaves Fit; got \(zoomValue())")
    }

    @MainActor
    func testFontSizeShortcutsMoved() throws {
        let file = try copyFixture("01-plain.docx", as: "FontSize.docx")
        app.launch()
        let window = try open(file)
        let body = window.textViews["Document body"]
        body.click()
        body.typeKey(.upArrow, modifierFlags: .command)
        body.typeKey(.rightArrow, modifierFlags: [.option, .shift])
        let size = window.comboBoxes["Font size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        let before = size.value as? String ?? ""
        body.typeKey(".", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitUntil(3) { (size.value as? String ?? "") != before }, "⇧⌘> makes the text bigger; still \(before)")
        let bigger = size.value as? String ?? ""
        body.typeKey(",", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(3) { (size.value as? String ?? "") == before }, "⇧⌘< undoes it; got \(bigger)")
        XCTAssertEqual(window.popUpButtons["Zoom"].value as? String, "100%", "font size keys don't zoom")
    }
}
