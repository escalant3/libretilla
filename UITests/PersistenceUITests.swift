import AppKit
import CartillaDocx
import XCTest

/// End-to-end checks of the persistence model (bootstrap §5.4, ADR 0003): edits reach the real
/// file with no Save action, quitting never prompts, and an untouched file stays untouched.
final class PersistenceUITests: CartillaUITestCase {
    @MainActor
    func testEditsAutosaveToTheRealFile() throws {
        let file = try copyFixture("01-plain.docx", as: "Autosave.docx")
        app.launch()
        let window = try open(file)
        typeAtStart("Autosaved line. ", in: window)
        XCTAssertTrue(try waitUntil(15) { try text(of: file).hasPrefix("Autosaved line. This is a plain paragraph") })
        XCTAssertTrue(window.staticTexts["saveStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(try waitUntil(5) { window.staticTexts["saveStatus"].value as? String == "Saved" })
    }

    @MainActor
    func testOpeningAndClosingWithoutEditingLeavesTheFileUntouched() throws {
        let file = try copyFixture("10-word-features.docx", as: "Untouched.docx")
        let before = try Data(contentsOf: file)
        let mtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        app.launch()
        let window = try open(file)
        RunLoop.current.run(until: Date().addingTimeInterval(5))  // longer than the autosave delay
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.count == 0, "closing an unedited document must not prompt")
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, mtime)
    }

    @MainActor
    func testQuittingWithUnsavedEditsSavesWithoutPrompting() throws {
        let file = try copyFixture("08-spanish.docx", as: "Quit.docx")
        app.launch()
        let window = try open(file)
        typeAtStart("Antes de salir. ", in: window)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "quit must not be blocked by a dialog")
        XCTAssertTrue(try text(of: file).contains("Antes de salir. "))
    }

    @MainActor
    func testKillLosesAtMostTheLastFewSeconds() throws {
        let file = try copyFixture("09-large.docx", as: "Crash.docx")
        app.launch()
        let window = try open(file)
        typeAtStart("Before the crash. ", in: window)
        XCTAssertTrue(try waitUntil(20) { try text(of: file).hasPrefix("Before the crash. ") })
        typeAtStart("Lost. ", in: window)
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).forEach { $0.forceTerminate() }
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let saved = try text(of: file)
        XCTAssertTrue(saved.hasPrefix("Before the crash. ") || saved.hasPrefix("Lost. Before the crash. "))
        XCTAssertTrue(saved.contains("Chapter 40"), "the file must be intact")
    }

    @MainActor
    func testClosingUnnamedDocuments() throws {
        app.launch()
        let untitled = app.windows.firstMatch
        XCTAssertTrue(untitled.waitForExistence(timeout: 10))
        // Empty: closes silently.
        untitled.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(try waitUntil(5) { app.windows.count == 0 })
        XCTAssertEqual(app.sheets.count, 0)

        // Non-empty: the standard sheet appears (ADR 0003), and Delete discards the draft.
        app.typeKey("n", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        typeAtStart("A draft worth keeping?", in: window)
        window.typeKey("w", modifierFlags: .command)
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "expected the keep/delete sheet")
        sheet.buttons["Delete"].click()
        XCTAssertTrue(try waitUntil(10) { app.windows.count == 0 })
    }
}
