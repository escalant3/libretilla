import AppKit
import XCTest

/// Milestone 4 in the real app: the outline sidebar, Settings, Dark Mode and an accessibility audit.
final class PolishUITests: CartillaUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every run starts from the defaults, whatever an earlier run left behind.
        app.launchArguments += ["-CartillaZoom", "1", "-CartillaUITestFreshDefaults", "YES"]
    }

    func shoot(_ element: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testOutlineSidebarListsHeadingsAndJumps() throws {
        let file = try copyFixture("09-large.docx", as: "Outline.docx")
        app.launch()
        let window = try open(file)
        let body = window.textViews["Document body"]
        body.click()
        let outline = window.tables["outline"]
        XCTAssertFalse(outline.exists && outline.isHittable, "the outline is hidden by default")

        body.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(outline.waitForExistence(timeout: 5), "⌃⌘S shows the outline")
        XCTAssertTrue(waitUntil(5) { outline.tableRows.count > 3 }, "headings are listed")
        shoot(window, "1-outline")

        // Clicking the last heading moves the caret there; typing goes into it.
        let last = outline.tableRows.element(boundBy: outline.tableRows.count - 1)
        last.click()
        body.typeText("Zz")
        XCTAssertTrue(
            waitUntil(5) { (last.staticTexts.firstMatch.value as? String)?.hasPrefix("Zz") == true },
            "typing went into the heading the outline jumped to")
        shoot(window, "2-outline-jumped")

        body.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(5) { !outline.exists || !outline.isHittable }, "⌃⌘S hides it again")
    }

    @MainActor
    func testSettingsChangeOpenWindows() throws {
        let file = try copyFixture("02-headings.docx", as: "Choices.docx")
        app.launch()
        let window = try open(file)
        window.textViews["Document body"].click()
        window.typeKey(",", modifierFlags: .command)
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, opens Settings")
        shoot(settings, "1-settings")

        let zoom = window.popUpButtons["Zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "format bar shown")
        settings.switches["showFormatBar"].click()
        XCTAssertTrue(waitUntil(5) { !zoom.exists || !zoom.isHittable }, "the format bar hides in the open window")
        settings.switches["showFormatBar"].click()
        XCTAssertTrue(waitUntil(5) { zoom.exists && zoom.isHittable })
    }

    /// Screenshots of the page in Dark Mode (dark page, then a light page from Settings), for review.
    @MainActor
    func testDarkModeScreenshots() throws {
        let file = try copyFixture("02-headings.docx", as: "Dark.docx")
        app.launchArguments += ["-CartillaUITestAppearance", "Dark"]
        app.launch()
        let window = try open(file)
        window.textViews["Document body"].click()
        window.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(window.tables["outline"].waitForExistence(timeout: 5))
        shoot(window, "1-dark-page")
        window.textViews["Document body"].click()
        window.typeKey(",", modifierFlags: .command)
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons[String(localized: "Light, as printed")].click()
        settings.switches["showPageEdges"].click()
        shoot(settings, "2-settings-dark")
        settings.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        shoot(window, "3-light-page-in-dark-mode")
        // Put the settings back for whoever runs the app next.
        window.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons[String(localized: "Dark")].click()
        settings.switches["showPageEdges"].click()
        settings.typeKey("w", modifierFlags: .command)
        window.typeKey("s", modifierFlags: [.command, .control])
    }

    /// Bootstrap §10 M4: "passes accessibility audit".
    @MainActor
    func testAccessibilityAudit() throws {
        let file = try copyFixture("02-headings.docx", as: "Audit.docx")
        app.launch()
        let window = try open(file)
        window.textViews["Document body"].click()
        window.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(window.tables["outline"].waitForExistence(timeout: 5))
        let body = window.textViews["Document body"].frame
        // On GitHub's runners the contrast audit flags plainly readable labels: Settings' "Page in Dark Mode" and
        // "Show format bar", the title bar's "Saved". Its own crops of them show black text on white or light
        // gray, waiting doesn't change it, and it marks the windows "Disabled". A false positive there: skip the
        // contrast check on CI only (CARTILLA_CI, set by the workflow through TEST_RUNNER_CARTILLA_CI). Every
        // other check runs on CI, and the whole audit runs everywhere else.
        let onCI = ProcessInfo.processInfo.environment["CARTILLA_CI"] != nil
        func exempt(_ issue: XCUIAccessibilityAuditIssue, in audited: XCUIElement) -> Bool {
            if onCI, issue.auditType == .contrast { return true }
            // A tooltip AppKit happens to show under the pointer isn't Cartilla's.
            if issue.element?.elementType == .helpTag { return true }
            // AppKit's window tab is labelled with the file name ("Audit.docx"), which the audit doesn't
            // consider readable; it's the system's tab, as in every document app.
            if issue.element?.elementType == .tab { return true }
            // The window title is AppKit's, drawn over the glass title bar.
            if issue.auditType == .contrast, issue.element?.value as? String == window.title { return true }
            // AppKit's window buttons (close, minimize, zoom) report a parent/child mismatch.
            let buttons = CGRect(x: audited.frame.minX, y: audited.frame.minY, width: 90, height: 40)
            if issue.auditType == .parentChild, let frame = issue.element?.frame, buttons.contains(frame) {
                return true
            }
            // The document's text colours are its author's; Cartilla keeps them on a white page (and only
            // lightens them on a dark page). The chrome, sidebar and Settings must pass.
            if issue.auditType == .contrast, let frame = issue.element?.frame, body.contains(frame) { return true }
            print("Audit issue: \(issue.compactDescription): \(String(describing: issue.element))")
            return false
        }
        // The document window's contents (not the Touch Bar NSTextView offers, which isn't on screen).
        try app.performAccessibilityAudit(for: .all) { issue in
            guard let frame = issue.element?.frame, window.frame.contains(frame) else { return true }
            return exempt(issue, in: window)
        }

        // Settings too.
        window.typeKey(",", modifierFlags: .command)
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        // Make sure Settings is the key window (its title bar) and has finished fading in, or its contrast is
        // measured dimmed or half-transparent.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // Only Settings itself: behind it, the document window is inactive and AppKit dims its title.
        try app.performAccessibilityAudit(for: .all) { issue in
            guard let frame = issue.element?.frame, settings.frame.contains(frame) else { return true }
            return exempt(issue, in: settings)
        }
        settings.typeKey("w", modifierFlags: .command)
        window.typeKey("s", modifierFlags: [.command, .control])
    }
}
