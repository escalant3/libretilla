import AppKit
import CartillaDocx
import XCTest

/// M2 end to end with real key events: shortcuts, the format bar, undo, the ruler and
/// Find and Replace, checked in the autosaved `.docx`.
final class FormattingUITests: CartillaUITestCase {
    func paragraphs(of url: URL) throws -> [Paragraph] {
        try OOXMLCodec().read(try Data(contentsOf: url)).body.blocks.compactMap {
            if case .paragraph(let p) = $0 { p } else { nil }
        }
    }

    func firstParagraph(of url: URL) throws -> Paragraph? {
        try paragraphs(of: url).first { $0.text.contains("plain paragraph") }
    }

    func firstWordIsBold(_ url: URL) throws -> Bool {
        guard let p = try firstParagraph(of: url) else { return false }
        for case .run(let r) in p.inlines where r.text.hasPrefix("This") { return r.properties.bold == true }
        return false
    }

    /// Selects the first word of the document.
    func selectFirstWord(in window: XCUIElement) -> XCUIElement {
        let body = window.textViews["Document body"]
        body.click()
        body.typeKey(.upArrow, modifierFlags: .command)
        body.typeKey(.rightArrow, modifierFlags: [.option, .shift])
        return body
    }

    @MainActor
    func testBoldShortcutAutosavesAndUndoRevertsIt() throws {
        let file = try copyFixture("01-plain.docx", as: "Bold.docx")
        app.launch()
        let window = try open(file)
        let body = selectFirstWord(in: window)
        body.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(try waitUntil(15) { try firstWordIsBold(file) }, "bold reaches the file")
        body.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(try waitUntil(15) { try !firstWordIsBold(file) }, "undo reaches the file")
        body.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(try waitUntil(15) { try firstWordIsBold(file) }, "redo reaches the file")
    }

    @MainActor
    func testHeadingAndListShortcuts() throws {
        let file = try copyFixture("01-plain.docx", as: "Shortcuts.docx")
        app.launch()
        let window = try open(file)
        let body = selectFirstWord(in: window)
        body.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(try waitUntil(15) { try firstParagraph(of: file)?.properties.styleId == "Heading1" })
        body.typeKey("0", modifierFlags: [.command, .option])
        body.typeKey("8", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            try waitUntil(15) {
                let p = try firstParagraph(of: file)
                return p?.properties.styleId != "Heading1" && p?.properties.hasNumbering == true
            })
    }

    @MainActor
    func testFormatBarAlignmentAndHiding() throws {
        let file = try copyFixture("01-plain.docx", as: "FormatBar.docx")
        app.launch()
        let window = try open(file)
        _ = selectFirstWord(in: window)
        let center = window.radioButtons["Center"].exists ? window.radioButtons["Center"] : window.buttons["Center"]
        XCTAssertTrue(center.waitForExistence(timeout: 5), "format bar alignment control")
        center.click()
        XCTAssertTrue(try waitUntil(15) { try firstParagraph(of: file)?.properties.alignment == "center" })

        // View ▸ Hide Format Bar.
        window.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(try waitUntil(5) { !center.isHittable })
        window.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(try waitUntil(5) { center.isHittable })
    }

    @MainActor
    func testRulerToggles() throws {
        let file = try copyFixture("01-plain.docx", as: "Ruler.docx")
        app.launch()
        let window = try open(file)
        window.textViews["Document body"].click()
        XCTAssertFalse(window.rulers.firstMatch.exists)
        window.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(window.rulers.firstMatch.waitForExistence(timeout: 5))
        window.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(try waitUntil(5) { !window.rulers.firstMatch.exists })
    }

    /// Opens a copy of the plain fixture and replaces every "paragraph" with "párrafo" from the find bar.
    /// Leaves the find bar open with focus in its Replace field.
    @MainActor
    func replaceAllParagraphs(as name: String) throws -> (file: URL, window: XCUIElement) {
        let file = try copyFixture("01-plain.docx", as: name)
        app.launch()
        let window = try open(file)
        window.textViews["Document body"].click()
        window.typeKey("f", modifierFlags: [.command, .option])
        let find = window.searchFields.firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        find.click()
        find.typeKey("a", modifierFlags: .command)
        find.typeText("paragraph")
        let replace = window.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'replace'"))
            .firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "replace field")
        replace.click()
        replace.typeKey("a", modifierFlags: .command)
        replace.typeText("párrafo")
        window.buttons["All"].click()
        return (file, window)
    }

    func everyParagraphReplaced(in file: URL) throws -> Bool {
        let t = try text(of: file)
        return t.contains("plain párrafo of text") && !t.contains("paragraph")
    }

    /// Saves the user's find string (the find pasteboard is shared by every app) and puts it back afterwards.
    func preserveFindPasteboard() {
        let findPasteboard = NSPasteboard(name: .find)
        let previous = findPasteboard.string(forType: .string)
        addTeardownBlock {
            findPasteboard.clearContents()
            if let previous { findPasteboard.setString(previous, forType: .string) }
        }
    }

    @MainActor
    func testFindAndReplaceAll() throws {
        preserveFindPasteboard()
        let (file, _) = try replaceAllParagraphs(as: "Replace.docx")
        XCTAssertTrue(try waitUntil(15) { try everyParagraphReplaced(in: file) })
    }

    /// DEBUG(ci/debug-find-replace-autosave): same as above, but closes the find bar after Replace All so
    /// focus goes back to the document. Tells us whether focus in the find bar is what blocks autosave on CI.
    @MainActor
    func testFindAndReplaceAllThenDone() throws {
        preserveFindPasteboard()
        let (file, window) = try replaceAllParagraphs(as: "ReplaceDone.docx")
        window.buttons["Done"].click()
        XCTAssertTrue(try waitUntil(15) { try everyParagraphReplaced(in: file) })
    }
}
