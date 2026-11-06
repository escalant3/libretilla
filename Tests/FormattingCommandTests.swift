import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// The Format menu / format bar commands, end to end through the real editor: command → text
/// view (undoable) → save → the `.docx` on disk.
@MainActor
final class FormattingCommandTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var doc: LibretillaDocument!
    var url: URL!
    var editor: EditorViewController { doc.editor! }
    var textView: LibretillaTextView { editor.textView }

    func open(_ fixture: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(fixture))
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(fixture)")
        try data.write(to: url)
        doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        doc.makeWindowControllers()
        doc.windowControllers.first?.window?.makeFirstResponder(textView)
    }

    override func tearDown() {
        doc?.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Saves to a new file and reads it back with the codec.
    func saved() throws -> DocxDocument {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).docx")
        defer { try? FileManager.default.removeItem(at: out) }
        let done = expectation(description: "saved")
        var failure: Error?
        doc.save(to: out, ofType: LibretillaDocument.docxType, for: .saveToOperation) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return try OOXMLCodec().read(try Data(contentsOf: out))
    }

    func select(_ s: String) throws {
        let r = (textView.string as NSString).range(of: s)
        XCTAssertNotEqual(r.location, NSNotFound, "\(s) not found")
        textView.setSelectedRange(r)
    }

    func caret(after s: String) throws {
        let r = (textView.string as NSString).range(of: s)
        XCTAssertNotEqual(r.location, NSNotFound, "\(s) not found")
        textView.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
    }

    func paragraph(_ s: String, in docx: DocxDocument) throws -> Paragraph {
        try XCTUnwrap(
            docx.body.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }.first {
                $0.text.contains(s)
            }, "no paragraph with \(s)")
    }

    func runs(_ p: Paragraph) -> [Run] {
        p.inlines.compactMap { if case .run(let r) = $0 { r } else { nil } }
    }

    /// Ends the current event, as the run loop would: closes the undo group and updates the change count.
    func menuItem(_ action: Selector, representedObject: String? = nil, tag: Int? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.representedObject = representedObject
        if let tag { item.tag = tag }
        return item
    }

    // MARK: Character formatting

    // Undo is checked end to end in FormattingUITests: in a unit test no event ends, so the
    // undo group a command opens never closes.

    func testBoldItalicAreSaved() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        editor.toggleBold(nil)
        editor.toggleItalic(nil)
        XCTAssertTrue(editor.currentFormat.bold && editor.currentFormat.italic)
        XCTAssertEqual(doc.undoManager?.canUndo, true)
        let p = try paragraph("plain paragraph", in: try saved())
        let run = try XCTUnwrap(runs(p).first { $0.text == "plain paragraph" })
        XCTAssertEqual(run.properties.bold, true)
        XCTAssertEqual(run.properties.italic, true)
        editor.toggleBold(nil)
        XCTAssertFalse(editor.currentFormat.bold)
        XCTAssertNil(
            runs(try paragraph("plain paragraph", in: try saved())).first { $0.text == "plain paragraph" }?.properties
                .bold)
    }

    func testFormattingAtACaretAppliesToTypedText() throws {
        try open("01-plain.docx")
        try caret(after: "written in the Normal style.")
        editor.toggleBold(nil)
        textView.insertText(" Bold words", replacementRange: textView.selectedRange())
        let p = try paragraph("Bold words", in: try saved())
        XCTAssertEqual(runs(p).first { $0.text.contains("Bold words") }?.properties.bold, true)
    }

    func testFontAndSizeFromTheFormatBar() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        let family = NSPopUpButton()
        family.addItem(withTitle: "Helvetica")
        family.lastItem?.representedObject = "Helvetica"
        editor.applyFontFamily(family)
        let size = NSComboBox()
        size.stringValue = "15"
        editor.applyFontSize(size)
        XCTAssertEqual(editor.currentFormat.fontFamily, "Helvetica")
        XCTAssertEqual(editor.currentFormat.fontSize, 15)
        let run = try XCTUnwrap(
            runs(try paragraph("plain paragraph", in: try saved())).first { $0.text == "plain paragraph" })
        XCTAssertEqual(run.properties.font, "Helvetica")
        XCTAssertEqual(run.properties.size, 15)
    }

    func testFontPanelChangesAreSavedAsWordProperties() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        // What the Font panel does: change display attributes through the text view.
        let r = textView.selectedRange()
        XCTAssertTrue(textView.shouldChangeText(in: r, replacementString: nil))
        textView.textStorage?.addAttribute(.font, value: NSFont(name: "Courier", size: 13)!, range: r)
        textView.didChangeText()
        let run = try XCTUnwrap(
            runs(try paragraph("plain paragraph", in: try saved())).first { $0.text == "plain paragraph" })
        XCTAssertEqual(run.properties.font, "Courier")
        XCTAssertEqual(run.properties.size, 13)
    }

    // MARK: Paragraphs and styles

    func testAlignmentLineSpacingAndIndent() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        editor.applyAlignment(menuItem(#selector(EditorViewController.applyAlignment(_:)), tag: 1))
        let spacing = menuItem(#selector(EditorViewController.applyLineSpacing(_:)))
        spacing.representedObject = 1.5
        editor.applyLineSpacing(spacing)
        editor.increaseIndent(nil)
        let p = try paragraph("plain paragraph", in: try saved())
        XCTAssertEqual(p.properties.alignment, "center")
        XCTAssertEqual(p.properties.line, 1.5)
        XCTAssertEqual(p.properties.indentLeft, 36)
    }

    func testHeadingStyleAndReturnContinuesInNormal() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        editor.applyParagraphStyle(
            menuItem(#selector(EditorViewController.applyParagraphStyle(_:)), representedObject: "builtin:heading 1"))
        XCTAssertEqual(editor.currentFormat.styleId, "Heading1")
        try caret(after: "written in the Normal style.")
        textView.insertNewline(nil)
        textView.insertText("Body text", replacementRange: textView.selectedRange())
        let saved = try saved()
        XCTAssertEqual(try paragraph("written in the Normal style", in: saved).properties.styleId, "Heading1")
        XCTAssertNil(try paragraph("Body text", in: saved).properties.styleId)
    }

    /// A new document, clicked below its (only) line: Title, type, Return. The title keeps its style and
    /// the next line is Normal. (The caret used to land after the last paragraph mark, where Return
    /// restyled the title and left the new line in Title.)
    func testReturnAfterTitleAtTheEndContinuesInNormal() throws {
        doc = LibretillaDocument()
        doc.makeWindowControllers()
        doc.windowControllers.first?.window?.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertEqual(textView.selectedRange().location, max(0, end - 1), "the caret stays in the last paragraph")
        editor.applyParagraphStyle(
            menuItem(#selector(EditorViewController.applyParagraphStyle(_:)), representedObject: "builtin:Title"))
        let title = try XCTUnwrap(doc.bridge.styles.styleId(named: "Title"))
        XCTAssertEqual(editor.currentFormat.styleId, title)
        textView.insertText("My Title", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        XCTAssertNotEqual(editor.currentFormat.styleId, title, "the new line is in the Normal style")
        textView.insertText("Body text", replacementRange: textView.selectedRange())
        let saved = try saved()
        XCTAssertEqual(try paragraph("My Title", in: saved).properties.styleId, title)
        XCTAssertNil(try paragraph("Body text", in: saved).properties.styleId)
    }

    func testMissingStyleIsAddedToTheDocument() throws {
        try open("12-pages.docx")
        XCTAssertNil(doc.bridge.styles.styleId(named: "heading 4"))
        let first = try XCTUnwrap(textView.string.split(separator: "\n").first { $0.count > 3 })
        try select(String(first))
        editor.applyParagraphStyle(
            menuItem(#selector(EditorViewController.applyParagraphStyle(_:)), representedObject: "builtin:heading 4"))
        let saved = try saved()
        let id = try XCTUnwrap(saved.styles.styleId(named: "heading 4"))
        XCTAssertEqual(try paragraph(String(first), in: saved).properties.styleId, id)
    }

    func testUpdateStyleToMatchSelection() throws {
        try open("02-headings.docx")
        let heading = try XCTUnwrap(
            doc.base?.body.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
                .first { $0.properties.styleId == "Heading2" })
        try select(heading.text)
        editor.applyAlignment(menuItem(#selector(EditorViewController.applyAlignment(_:)), tag: 2))
        editor.updateStyleToMatchSelection(nil)
        let saved = try saved()
        XCTAssertEqual(saved.styles.resolveParagraphStyle("Heading2").0.alignment, "right")
        XCTAssertNil(try paragraph(heading.text, in: saved).properties.alignment, "moved into the style")
        // Other Heading 2 paragraphs follow the style.
        let others = saved.body.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
            .filter { $0.properties.styleId == "Heading2" && $0.text != heading.text }
        for p in others { XCTAssertNil(p.properties.alignment) }
    }

    func testClearFormatting() throws {
        try open("01-plain.docx")
        try select("A second paragraph follows")
        let p0 = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        textView.setSelectedRange(p0)
        editor.clearFormatting(nil)
        let p = try paragraph("A second paragraph follows", in: try saved())
        for r in runs(p) {
            XCTAssertNil(r.propertiesXML.map { String(decoding: $0, as: UTF8.self) }, r.text)
        }
    }

    // MARK: Lists

    func testBulletsReturnAndTabBehaveLikeWord() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        editor.toggleBulletedList(nil)
        XCTAssertEqual(editor.currentFormat.list, .bullet)
        // Return at the end continues the list; Tab at the start of the new item nests it.
        try caret(after: "written in the Normal style.")
        textView.insertNewline(nil)
        textView.insertTab(nil)
        textView.insertText("Nested", replacementRange: textView.selectedRange())
        // Return on an empty item ends the list.
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        textView.insertText("After", replacementRange: textView.selectedRange())
        let saved = try saved()
        let first = try paragraph("plain paragraph", in: saved)
        let nested = try paragraph("Nested", in: saved)
        XCTAssertTrue(first.properties.hasNumbering)
        XCTAssertEqual(nested.properties.numId, first.properties.numId)
        XCTAssertEqual(nested.properties.ilvl, 1)
        XCTAssertFalse(try paragraph("After", in: saved).properties.hasNumbering)
        XCTAssertTrue(saved.numbering.isBullet(numId: try XCTUnwrap(first.properties.numId)))
    }

    func testNumberedListContinuesTheListAbove() throws {
        try open("01-plain.docx")
        try select("plain paragraph")
        editor.toggleNumberedList(nil)
        try select("A second paragraph")
        editor.toggleNumberedList(nil)
        let saved = try saved()
        let a = try paragraph("plain paragraph", in: saved).properties.numId
        let b = try paragraph("A second paragraph", in: saved).properties.numId
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        let style =
            textView.textStorage?.attribute(.paragraphStyle, at: textView.selectedRange().location, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertEqual(style?.textLists.last?.markerFormat.rawValue, "2.")
    }

    func testDeadKeysAndInputMethodsDoNotLeaveFormatting() throws {
        try open("08-spanish.docx")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // ´ then e, as with a Spanish keyboard: the accent is marked text until the second key.
        textView.setMarkedText(
            "´", selectedRange: NSRange(location: 1, length: 0), replacementRange: textView.selectedRange())
        textView.insertText("é", replacementRange: textView.markedRange())
        textView.setMarkedText(
            "˜", selectedRange: NSRange(location: 1, length: 0), replacementRange: textView.selectedRange())
        textView.insertText("ñ", replacementRange: textView.markedRange())
        let saved = try saved()
        let p = try XCTUnwrap(
            saved.body.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }.first)
        XCTAssertTrue(p.text.hasPrefix("éñ"), p.text)
        for r in runs(p) where r.text.contains("é") {
            XCTAssertNil(r.properties.underline, "marked-text underline must not be saved")
            XCTAssertNil(r.properties.highlight)
            XCTAssertNil(r.properties.color)
        }
    }

    // MARK: Read-only and opening

    func testOpeningAListDocumentDoesNotMarkItEdited() throws {
        try open("03-nested-lists.docx")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))  // let deferred renumbering run
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.undoManager?.canUndo, false)
    }
}
