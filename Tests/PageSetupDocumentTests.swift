import AppKit
import LibretillaDocx
import PDFKit
import XCTest

@testable import Libretilla

/// M3 page setup and PDF export through the real document, editor and save path.
@MainActor
final class PageSetupDocumentTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-pages-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws -> LibretillaDocument {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        let doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        doc.makeWindowControllers()
        return doc
    }

    func saved(_ doc: LibretillaDocument) throws -> DocxDocument {
        let url = scratch.appendingPathComponent("\(UUID()).docx")
        let done = expectation(description: "saved")
        var failure: Error?
        doc.save(to: url, ofType: LibretillaDocument.docxType, for: .saveToOperation) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return try OOXMLCodec().read(try Data(contentsOf: url))
    }

    func pdfPages(_ doc: LibretillaDocument) throws -> PDFDocument {
        let url = scratch.appendingPathComponent("\(UUID()).pdf")
        try doc.writePDF(to: url, showsProgress: false)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    func testEditorFollowsTheDocumentsPageSize() throws {
        let a4 = try open("07-header-footer.docx")
        let editor = try XCTUnwrap(a4.editor)
        XCTAssertEqual(editor.pageSetup.width, 11906)
        XCTAssertEqual(editor.textView.frame.width, a4.pageSetup.textWidth, accuracy: 0.5)
        XCTAssertEqual(editor.textView.textContainerInset.height, 72)
        XCTAssertFalse(a4.isDocumentEdited, "opening never marks a document edited")
        XCTAssertEqual(a4.printInfo.paperSize.width, 595.3, accuracy: 1)

        let letter = try open("01-plain.docx")
        XCTAssertEqual(try XCTUnwrap(letter.editor).textView.frame.width, 468)
    }

    func testNewDocumentsAreA4InCharter() throws {
        let doc = LibretillaDocument()
        doc.makeWindowControllers()
        XCTAssertEqual(doc.pageSetup, .a4)
        let tv = try XCTUnwrap(doc.editor?.textView)
        XCTAssertEqual(tv.frame.width, PageSetup.a4.textWidth, accuracy: 0.5)
        tv.insertText("Hola", replacementRange: NSRange(location: 0, length: 0))
        let font = try XCTUnwrap(tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.familyName, "Charter")
        XCTAssertEqual(font.pointSize, 12)

        let saved = try saved(doc)
        XCTAssertEqual(saved.body.pageSetup, .a4)
        let (_, normal) = saved.styles.resolveParagraphStyle(nil)
        XCTAssertEqual(saved.styles.fontFamily(for: normal), "Charter")
        XCTAssertEqual(normal.size, 12)
    }

    func testPaperFillsTheWindowUnlessPageEdgesAreShown() throws {
        let editor = EditorViewController()
        editor.loadView()
        let scroll = try XCTUnwrap(editor.view as? NSScrollView)
        let canvas = try XCTUnwrap(scroll.documentView as? PageCanvasView)
        XCTAssertFalse(editor.showsPageEdges)
        XCTAssertEqual(scroll.backgroundColor, .textBackgroundColor)

        scroll.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.layoutSubtreeIfNeeded()
        // The text column stays at the document's text width, centred, and starts at the top.
        XCTAssertEqual(editor.textView.frame.width, PageSetup.a4.textWidth, accuracy: 0.5)
        XCTAssertEqual(editor.textView.frame.midX, canvas.bounds.midX, accuracy: 1)
        XCTAssertEqual(editor.textView.frame.minY, 0)

        editor.showsPageEdges = true
        canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.backgroundColor, .underPageBackgroundColor)
        XCTAssertEqual(editor.textView.frame.minY, 32)
        XCTAssertEqual(canvas.pageRect.width, PageSetup.a4.pageSize.width, accuracy: 0.5)
    }

    func testPageSetupChangeIsUndoableAndSaved() throws {
        let doc = try open("01-plain.docx")
        var setup = doc.pageSetup
        setup.left = 2880
        doc.setPageSetup(setup)
        XCTAssertEqual(doc.editor?.textView.frame.width ?? 0, 396, accuracy: 0.5)
        XCTAssertEqual(doc.printInfo.leftMargin, 144)
        XCTAssertEqual(try saved(doc).body.pageSetup.left, 2880)

        doc.undoManager?.undo()
        XCTAssertEqual(doc.pageSetup, .letter)
        XCTAssertEqual(doc.editor?.textView.frame.width ?? 0, 468, accuracy: 0.5)
        XCTAssertEqual(try saved(doc).body.pageSetup, .letter)
    }

    func testPageSetupSheetChangesPaperAndOrientationButKeepsMargins() throws {
        let doc = try open("01-plain.docx")
        let info = doc.printInfo.copy() as! NSPrintInfo
        info.paperSize = PageSetup.a4.pageSize
        info.orientation = .landscape
        XCTAssertTrue(doc.shouldChangePrintInfo(info))
        let setup = doc.pageSetup
        XCTAssertTrue(setup.isLandscape)
        XCTAssertEqual(setup.width, 16838)
        XCTAssertEqual(setup.height, 11906)
        XCTAssertEqual(setup.left, 1440)
        XCTAssertEqual(try saved(doc).body.pageSetup, setup)
    }

    func testPDFUsesTheDocumentsPaperSize() throws {
        let a4 = try pdfPages(try open("07-header-footer.docx"))
        let a4Box = try XCTUnwrap(a4.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(a4Box.width, 595.3, accuracy: 0.5)
        XCTAssertEqual(a4Box.height, 841.9, accuracy: 0.5)

        let letter = try pdfPages(try open("01-plain.docx"))
        let letterBox = try XCTUnwrap(letter.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(letterBox.size, CGSize(width: 612, height: 792))
        XCTAssertEqual(letter.pageCount, 1)
        XCTAssertTrue(letter.string?.contains("This is a plain paragraph of text") ?? false)
    }

    func testPDFPaginatesALongDocumentAndKeepsTheLastLine() throws {
        let doc = try open("09-large.docx")
        let pdf = try pdfPages(doc)
        XCTAssertGreaterThan(pdf.pageCount, 50)
        let lastWords = try XCTUnwrap(
            doc.editor?.textView.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                .split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " "))
        // The document ends with a page break, so (as in Word) the last page is empty and the text ends on
        // the page before.
        XCTAssertTrue(
            pdf.page(at: pdf.pageCount - 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let lastTextPage = try XCTUnwrap(pdf.page(at: pdf.pageCount - 2)?.string)
        XCTAssertTrue(
            lastTextPage.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(lastWords),
            "last text page ends with \(lastWords)")
    }

    func testPDFOfALandscapeDocumentIsWide() throws {
        let doc = try open("01-plain.docx")
        var setup = doc.pageSetup
        (setup.width, setup.height, setup.isLandscape) = (setup.height, setup.width, true)
        doc.setPageSetup(setup)
        let box = try XCTUnwrap(try pdfPages(doc).page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.size, CGSize(width: 792, height: 612))
    }

    // MARK: Page breaks

    func testPageBreaksStartNewPagesInThePDFWithoutTheirChips() throws {
        // Three short sections separated by Word page breaks, then "Last page."
        let pdf = try pdfPages(try open("07-header-footer.docx"))
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertTrue(pdf.page(at: 3)?.string?.contains("Last page.") ?? false)
        XCTAssertFalse(pdf.string?.contains("Page break") ?? true)
        XCTAssertFalse(pdf.string?.contains("\u{FFFC}") ?? true, "no object characters in the PDF's text")
    }

    /// Insert ▸ Page Break goes to the first responder, the text view: the editor must be the first in the chain
    /// to handle it. (Named `insertPageBreak:`, it was handled by NSTextView, which inserts a bare U+000C.)
    func testPageBreakMenuActionReachesTheEditorFromTheTextView() throws {
        let doc = try open("01-plain.docx")
        let editor = try XCTUnwrap(doc.editor)
        let item = try XCTUnwrap(
            MainMenu.make().items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Page Break" })
        let action = try XCTUnwrap(item.action)
        var responder: NSResponder? = editor.textView
        while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
        XCTAssertTrue(responder === editor, "handled by \(String(describing: responder))")
    }

    func testInsertPageBreakIsOneUndoStepAndIsSaved() throws {
        let doc = try open("01-plain.docx")
        let editor = try XCTUnwrap(doc.editor)
        let tv = editor.textView!
        XCTAssertEqual(try pdfPages(doc).pageCount, 1)

        let at = (tv.string as NSString).range(of: "A second paragraph").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        editor.insertDocumentPageBreak(nil)
        XCTAssertEqual(tv.textStorage?.attribute(.libretillaPageBreak, at: at, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(tv.selectedRange().location, at + 2, "the caret starts the next page")
        XCTAssertEqual(try pdfPages(doc).pageCount, 2)

        let saved = try saved(doc)
        XCTAssertTrue(saved.body.plainText.contains("\u{000C}\nA second paragraph"))

        doc.undoManager?.undo()
        XCTAssertNil(tv.textStorage?.attribute(.libretillaPageBreak, at: at, effectiveRange: nil))
        XCTAssertFalse(try self.saved(doc).body.plainText.contains("\u{000C}"))
    }

    // MARK: Page break before

    /// The first line of text on a PDF page (0-based), not counting the page's header.
    func firstLine(of page: Int, in pdf: PDFDocument, header: String? = nil) -> String? {
        pdf.page(at: page)?.string?.split(whereSeparator: \.isNewline).map(String.init).first { $0 != header }
    }

    func testPageBreakBeforeStartsNewPagesInThePDF() throws {
        let pdf = try pdfPages(try open("13-page-break-before.docx"))
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertEqual(
            (0..<pdf.pageCount).map { firstLine(of: $0, in: pdf) },
            [
                "Page break before", "Direct: starts page 2.", "Chapter style: starts page 3.",
                "Part style (based on Chapter): starts page 4.",
            ],
            "no blank page before the first paragraph")
        let third = try XCTUnwrap(pdf.page(at: 2)?.string)
        for text in ["Chapter style, turned off directly", "Interlude style", "Direct, turned off with false"] {
            XCTAssertTrue(third.contains(text), "\(text) stays on page 3")
        }
    }

    /// Marks the paragraph holding `text` in the editor as starting a new page.
    func markPageBreakBefore(_ text: String, in doc: LibretillaDocument) throws {
        let storage = try XCTUnwrap(doc.editor?.textView.textStorage)
        let ns = storage.string as NSString
        let found = ns.range(of: text)
        XCTAssertNotEqual(found.location, NSNotFound)
        storage.addAttribute(.libretillaPageBreakBefore, value: true, range: ns.paragraphRange(for: found))
    }

    func testPageBreakBeforeMidPageAddsAPage() throws {
        let doc = try open("01-plain.docx")
        XCTAssertEqual(try pdfPages(doc).pageCount, 1)
        try markPageBreakBefore("Centered paragraph.", in: doc)
        let pdf = try pdfPages(doc)
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(firstLine(of: 1, in: pdf), "Centered paragraph.")
    }

    func testPageBreakBeforeAfterAPageBreakAddsNoBlankPage() throws {
        // "Last page." follows a Word page break, so it already starts page 4.
        let doc = try open("07-header-footer.docx")
        try markPageBreakBefore("Last page.", in: doc)
        let pdf = try pdfPages(doc)
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertEqual(firstLine(of: 3, in: pdf, header: "Libretilla fixture — running header"), "Last page.")
    }
}
