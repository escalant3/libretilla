import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// Milestone 4: the outline sidebar, VoiceOver's heading rotor, Dark Mode and Settings.
@MainActor
final class PolishTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")
    static let touchedKeys = [
        Preferences.keepsPageLightKey, Preferences.rulerUnitsKey, Preferences.outlineShownKey,
        DocumentWindowController.showsPageEdgesKey, DocumentWindowController.formatBarHiddenKey,
    ]

    var scratch: URL!
    var doc: LibretillaDocument!
    var editor: EditorViewController { doc.editor! }
    var windowController: DocumentWindowController { doc.windowControllers.first as! DocumentWindowController }

    override func setUpWithError() throws {
        for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-polish-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        doc?.close()
        for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        makeWindow(for: doc)
    }

    // MARK: Outline

    func testOutlineListsTitleAndHeadingsInOrder() throws {
        try open("02-headings.docx")
        editor.updateOutline()
        XCTAssertEqual(
            editor.headings.map(\.title),
            ["Document Title", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Heading 5", "Heading 6"],
            "Subtitle, Quote and Code aren't headings")
        XCTAssertEqual(editor.headings.map(\.level), [0, 1, 2, 3, 4, 5, 6])
        let text = editor.textView.string as NSString
        for h in editor.headings { XCTAssertEqual(text.substring(with: h.range), h.title) }
    }

    func testOutlineFollowsStyleChangesAndTyping() throws {
        try open("01-plain.docx")
        editor.updateOutline()
        XCTAssertTrue(editor.headings.isEmpty)
        let text = editor.textView.string as NSString
        let at = text.range(of: "plain paragraph")
        XCTAssertNotEqual(at.location, NSNotFound)
        editor.textView.setSelectedRange(NSRange(location: at.location, length: 0))
        let item = NSMenuItem(
            title: "", action: #selector(EditorViewController.applyParagraphStyle(_:)), keyEquivalent: "")
        item.representedObject = "builtin:heading 2"
        editor.applyParagraphStyle(item)
        editor.updateOutline()
        XCTAssertEqual(editor.headings.count, 1)
        XCTAssertEqual(editor.headings.first?.level, 2)

        // Typing in the heading changes its title; the outline keeps up.
        let heading = try XCTUnwrap(editor.headings.first)
        editor.textView.insertText(
            "New words. ", replacementRange: NSRange(location: heading.range.location, length: 0))
        editor.updateOutline()
        XCTAssertEqual(editor.headings.first?.range.location, heading.range.location)
        XCTAssertEqual(editor.headings.first?.title.hasPrefix("New words. "), true)
    }

    func testClickingAHeadingMovesTheCaretThere() throws {
        try open("09-large.docx")
        editor.updateOutline()
        doc.showWindows()
        // A heading in the middle (the view can't scroll the last one to the top: the document ends first).
        let last = editor.headings[editor.headings.count * 3 / 4]
        editor.go(to: last)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: last.range.location, length: 0))
        let scroll = try XCTUnwrap(editor.textView.enclosingScrollView)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 1000, "the view scrolled down to the last heading")
        let caret = editor.textView.firstRect(forCharacterRange: last.range, actualRange: nil)
        let window = try XCTUnwrap(editor.view.window)
        let canvas = try XCTUnwrap(scroll.documentView)
        let inCanvas = canvas.convert(window.convertFromScreen(caret), from: nil)
        let gap = inCanvas.minY - scroll.documentVisibleRect.minY
        XCTAssertTrue((0...40).contains(gap), "the heading is at the top of the view (\(gap) pt below it)")
    }

    func testOutlineToggleIsRememberedAndOffByDefault() throws {
        try open("02-headings.docx")
        XCTAssertFalse(windowController.isOutlineShown)
        windowController.toggleOutline(nil)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Preferences.outlineShownKey))
        let item = NSMenuItem(
            title: "", action: #selector(DocumentWindowController.toggleOutline(_:)), keyEquivalent: "")
        _ = windowController.validateMenuItem(item)
        XCTAssertEqual(item.title, String(localized: "Hide Outline"))
    }

    func testHeadingTitlesDropObjectsAndExtraSpace() {
        XCTAssertEqual(DocumentOutline.displayTitle("\u{FFFC} Chapter\t one  "), "Chapter one")
        XCTAssertEqual(DocumentOutline.displayTitle("\u{FFFC}"), "")
    }

    // MARK: VoiceOver

    func testHeadingRotorMovesBetweenHeadings() throws {
        try open("02-headings.docx")
        let rotors = editor.textView.accessibilityCustomRotors()
        XCTAssertTrue(rotors.contains { $0.type == .heading })
        let headings = editor.currentHeadings()
        let first = LibretillaTextView.headingSearch(headings, from: nil, direction: .next, filter: "")
        XCTAssertEqual(first?.title, "Document Title")
        let second = LibretillaTextView.headingSearch(headings, from: first?.range, direction: .next, filter: "")
        XCTAssertEqual(second?.title, "Heading 1")
        XCTAssertEqual(
            LibretillaTextView.headingSearch(headings, from: second?.range, direction: .previous, filter: "")?.title,
            "Document Title")
        XCTAssertEqual(
            LibretillaTextView.headingSearch(headings, from: nil, direction: .previous, filter: "")?.title, "Heading 6")
        XCTAssertEqual(
            LibretillaTextView.headingSearch(headings, from: nil, direction: .next, filter: "ing 4")?.title, "Heading 4"
        )
    }

    // MARK: Dark Mode

    func testDarkColoursAreDrawnLighterOnADarkPage() throws {
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(EditorViewController.readableColor(black, onHighlight: false), .textColor)
        let navy = NSColor(srgbRed: 0x1F / 255.0, green: 0x38 / 255.0, blue: 0x64 / 255.0, alpha: 1)
        let lighter = try XCTUnwrap(
            EditorViewController.readableColor(navy, onHighlight: false)?.usingColorSpace(NSColorSpace.sRGB))
        XCTAssertGreaterThanOrEqual(EditorViewController.luminance(lighter), 0.25)
        XCTAssertGreaterThan(lighter.blueComponent, lighter.redComponent, "it stays blue")
        let orange = NSColor(srgbRed: 0xED / 255.0, green: 0x7D / 255.0, blue: 0x31 / 255.0, alpha: 1)
        XCTAssertNil(EditorViewController.readableColor(orange, onHighlight: false), "bright colours are left alone")
        XCTAssertNil(EditorViewController.readableColor(.textColor, onHighlight: false), "automatic colour adapts")
        XCTAssertEqual(EditorViewController.readableColor(.textColor, onHighlight: true), .black)
    }

    func testDarkModeDoesNotChangeTheDocument() throws {
        try open("02-headings.docx")
        let before = editor.textSnapshot()
        let undoable = doc.undoManager?.canUndo
        editor.view.appearance = NSAppearance(named: .darkAqua)
        editor.textView.viewDidChangeEffectiveAppearance()
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.display()
        XCTAssertTrue(editor.pageIsDark)
        XCTAssertEqual(editor.textSnapshot(), before)
        XCTAssertEqual(doc.undoManager?.canUndo, undoable)
        XCTAssertFalse(doc.isDocumentEdited)
    }

    /// Backlog 28: table text is drawn readable on a dark page.
    func testTablesAreReadableOnADarkPage() throws {
        try open("04-tables.docx")
        editor.view.appearance = NSAppearance(named: .darkAqua)
        editor.textView.viewDidChangeEffectiveAppearance()
        editor.view.layoutSubtreeIfNeeded()
        let tv = try XCTUnwrap(editor.textView)
        let first = (tv.string as NSString).range(of: "\u{FFFC}").location
        let layout = try XCTUnwrap(tv.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        layout.ensureLayout(for: layout.documentRange)
        func frame(_ offset: Int) throws -> CGRect {
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
            return try XCTUnwrap(layout.textLayoutFragment(for: location)).layoutFragmentFrame
                .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        }
        let table = try frame(first).union(try frame(first + 6))
        let rep = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: table))
        // The page behind the text view, then the text.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        NSGraphicsContext.restoreGraphicsState()
        tv.cacheDisplay(in: table, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dark-table.png"))
        var bright = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                if c.brightnessComponent > 0.7 && c.saturationComponent < 0.2 { bright += 1 }
            }
        }
        XCTAssertGreaterThan(bright, 200, "light text and lines on the dark page")
    }

    func testLightPageSettingKeepsThePageAsPrinted() throws {
        try open("02-headings.docx")
        editor.view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(editor.pageIsDark)
        UserDefaults.standard.set(true, forKey: Preferences.keepsPageLightKey)
        windowController.applyPreferences()
        XCTAssertTrue(editor.keepsPageLight)
        XCTAssertFalse(editor.pageIsDark)
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testPrintingIsAlwaysOnWhitePaper() {
        let view = PrintTextView(text: NSAttributedString(string: "Hello"), width: 400)
        XCTAssertEqual(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    // MARK: Settings

    func testSettingsApplyToOpenWindows() throws {
        try open("01-plain.docx")
        UserDefaults.standard.set(true, forKey: DocumentWindowController.showsPageEdgesKey)
        windowController.applyPreferences()
        XCTAssertTrue(editor.showsPageEdges)

        let textView = editor.textView!
        doc.windowControllers.first?.window?.makeFirstResponder(textView)
        textView.toggleRuler(nil)
        UserDefaults.standard.set(Preferences.RulerUnit.points.rawValue, forKey: Preferences.rulerUnitsKey)
        windowController.applyPreferences()
        XCTAssertEqual(textView.enclosingScrollView?.horizontalRulerView?.measurementUnits, .init("Points"))
        UserDefaults.standard.set(Preferences.RulerUnit.centimeters.rawValue, forKey: Preferences.rulerUnitsKey)
        windowController.applyPreferences()
        XCTAssertEqual(textView.enclosingScrollView?.horizontalRulerView?.measurementUnits, .init("Centimeters"))
        textView.toggleRuler(nil)
    }

    func testSettingsWindowOpens() throws {
        let settings = SettingsWindowController.shared
        settings.show()
        defer { settings.close() }
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.contentLayoutRect.height, 100)
    }
}
