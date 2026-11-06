import AppKit
import LibretillaDocx
import PDFKit
import XCTest

@testable import Libretilla

/// Headers and footers (ADR 0007) in print and PDF, through the real document.
extension PageSetupDocumentTests {
    func pageText(_ pdf: PDFDocument, _ page: Int) -> String { pdf.page(at: page)?.string ?? "" }

    /// Where `text` is drawn on `page`, in PDF points (origin at the bottom left).
    func bounds(of text: String, on page: Int, in pdf: PDFDocument) throws -> CGRect {
        let page = try XCTUnwrap(pdf.page(at: page))
        let selection = try XCTUnwrap(pdf.findString(text, withOptions: []).first { $0.pages.first == page })
        return selection.bounds(for: page)
    }

    func testHeadersAndFootersPrintOnTheirPagesWithPageNumbers() throws {
        let pdf = try pdfPages(try open("14-headers-footers.docx"))
        XCTAssertEqual(pdf.pageCount, 5)
        // Page 1: the first-page header, and no footer (the section has no first-page footer).
        XCTAssertTrue(pageText(pdf, 0).contains("Cover page header"))
        XCTAssertFalse(pageText(pdf, 0).contains("Odd page header"))
        XCTAssertFalse(pageText(pdf, 0).contains("Page 1"))
        // Even pages: the even ones; the footer's page number is inside a content control.
        XCTAssertTrue(pageText(pdf, 1).contains("Even page header"))
        XCTAssertTrue(pageText(pdf, 1).contains("Even page 2"))
        XCTAssertTrue(pageText(pdf, 3).contains("Even page 4"))
        // Odd pages after the first: the default ones, with "Page X of Y".
        XCTAssertTrue(pageText(pdf, 2).contains("Odd page header"))
        XCTAssertTrue(pageText(pdf, 2).contains("Page 3 of 5"))
        XCTAssertTrue(pageText(pdf, 4).contains("Page 5 of 5"))
        XCTAssertFalse(pdf.string?.contains("\u{FFFC}") ?? true, "no chips in the PDF's text")
    }

    func testHeaderAndFooterSitAtTheirDistancesFromTheEdges() throws {
        let pdf = try pdfPages(try open("14-headers-footers.docx"))
        let page = try XCTUnwrap(pdf.page(at: 2)).bounds(for: .mediaBox)
        // w:header and w:footer are 720 twips (36 pt); the side margins 1440 (72 pt). The header is right-aligned.
        let header = try bounds(of: "Odd page header", on: 2, in: pdf)
        XCTAssertEqual(header.maxY, page.height - 36, accuracy: 4)
        XCTAssertEqual(header.maxX, page.width - 72, accuracy: 2)
        let footer = try bounds(of: "Page 3 of 5", on: 2, in: pdf)
        XCTAssertEqual(footer.minY, 36, accuracy: 6)
        XCTAssertEqual(footer.midX, page.width / 2, accuracy: 2, "centred")
        // The body text stays inside the margins, below the header.
        let body = try bounds(of: "Headers and footers", on: 0, in: pdf)
        XCTAssertLessThan(body.maxY, page.height - 72 + 1)
    }

    // MARK: The Header and Footer sheet

    /// Opens Format ▸ Header and Footer… on `doc`.
    func openHeaderFooterSheet(_ doc: LibretillaDocument) throws -> HeaderFooterController {
        let editor = try XCTUnwrap(doc.editor)
        editor.editHeaderAndFooter(nil)
        return try XCTUnwrap(editor.headerFooterEditor)
    }

    /// Types `text` at the end of the sheet's header or footer.
    func type(_ text: String, in kind: HeadersFooters.Kind, _ sheet: HeaderFooterController) throws {
        let tv = try XCTUnwrap(sheet.textViews[kind])
        sheet.window?.makeFirstResponder(tv)
        let end = max(0, tv.string.count - 1)
        tv.setSelectedRange(NSRange(location: end, length: 0))
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    func testSheetAddsAFooterWithPageNumberAndCount() throws {
        let doc = try open("01-plain.docx")
        let editor = try XCTUnwrap(doc.editor)
        let tv = try XCTUnwrap(editor.textView)
        for text in ["A second paragraph", "Centered paragraph."] {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: text).location, length: 0))
            editor.insertPageBreak(nil)
        }
        XCTAssertEqual(try pdfPages(doc).pageCount, 3)

        let sheet = try openHeaderFooterSheet(doc)
        try type("Page ", in: .footer, sheet)
        sheet.insertPageNumber(nil)
        try type(" of ", in: .footer, sheet)
        sheet.insertPageCount(nil)
        sheet.done(nil)

        let pdf = try pdfPages(doc)
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(pageText(pdf, 0).contains("Page 1 of 3"))
        XCTAssertTrue(pageText(pdf, 1).contains("Page 2 of 3"))
        XCTAssertTrue(pageText(pdf, 2).contains("Page 3 of 3"))

        let saved = try saved(doc)
        let footer = try XCTUnwrap(saved.headersFooters.stories[.init(.footer, .default)])
        XCTAssertEqual(footer.printableBody(page: 2, pages: 3).plainText, "Page 2 of 3")
        XCTAssertNil(saved.headersFooters.stories[.init(.header, .default)], "the empty header makes no part")
        XCTAssertEqual(footer.partName, "word/footer1.xml")
        // New documents' footers use Word's Footer style.
        XCTAssertTrue(String(decoding: saved.package["word/footer1.xml"]!, as: UTF8.self).contains("w:pStyle"))

        doc.undoManager?.undo()
        XCTAssertFalse(pageText(try pdfPages(doc), 1).contains("Page 2"), "one undo step removes the footer")
        XCTAssertTrue(try self.saved(doc).headersFooters.stories.isEmpty)
    }

    func testSheetAddsAFirstPageHeader() throws {
        let doc = try open("07-header-footer.docx")
        let sheet = try openHeaderFooterSheet(doc)
        XCTAssertTrue(sheet.pages.isHidden)
        sheet.differentFirstPage.performClick(nil)
        XCTAssertFalse(sheet.pages.isHidden)
        sheet.pages.selectedSegment = 0
        sheet.choosePages(nil)
        XCTAssertEqual(sheet.slot, .first)
        XCTAssertEqual(sheet.textViews[.header]?.string, "\n", "a new, empty first-page header")
        try type("Cover", in: .header, sheet)
        sheet.done(nil)

        let pdf = try pdfPages(doc)
        XCTAssertTrue(pageText(pdf, 0).contains("Cover"))
        XCTAssertFalse(pageText(pdf, 0).contains("running header"))
        XCTAssertFalse(pageText(pdf, 0).contains("Page 1"), "no first-page footer")
        XCTAssertTrue(pageText(pdf, 1).contains("running header"))
        XCTAssertTrue(pageText(pdf, 1).contains("Page 2"))

        let saved = try saved(doc)
        XCTAssertTrue(saved.body.differentFirstPage)
        XCTAssertEqual(saved.headersFooters.stories[.init(.header, .first)]?.body.plainText, "Cover")
    }

    func testSheetShowsFieldsAsChipsAndCancelChangesNothing() throws {
        let doc = try open("14-headers-footers.docx")
        let sheet = try openHeaderFooterSheet(doc)
        XCTAssertEqual(sheet.slot, .default)
        XCTAssertEqual(sheet.differentFirstPage.state, .on)
        let footer = try XCTUnwrap(sheet.textViews[.footer]?.textStorage)
        var chips = 0
        footer.enumerateAttribute(.attachment, in: NSRange(location: 0, length: footer.length)) { v, _, _ in
            if v != nil { chips += 1 }
        }
        XCTAssertEqual(chips, 2, "page number and page count")
        XCTAssertEqual(sheet.textViews[.header]?.string, "Odd page header\n")

        try type(" edited", in: .header, sheet)
        sheet.cancel(nil)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.headersFooters.stories[.init(.header, .default)]?.body.plainText, "Odd page header")
    }

    func testSheetEditKeepsOtherPartsByteForByte() throws {
        let doc = try open("14-headers-footers.docx")
        let before = try OOXMLCodec().read(try Data(contentsOf: try XCTUnwrap(doc.fileURL)))
        let sheet = try openHeaderFooterSheet(doc)
        try type(" (edited)", in: .header, sheet)
        sheet.done(nil)
        let saved = try saved(doc)
        XCTAssertEqual(
            saved.headersFooters.stories[.init(.header, .default)]?.body.plainText, "Odd page header (edited)")
        for name in ["word/header1.xml", "word/header3.xml", "word/footer1.xml", "word/footer2.xml"] {
            XCTAssertEqual(saved.package[name], before.package[name], name)
        }
    }
}
