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

    /// Gap G4: list markers are drawn at Word's hanging indent and the text starts at the left indent, in print as in
    /// the editor (the same layout).
    func testListMarkersPrintAtWordsIndents() throws {
        let doc = try open("03-nested-lists.docx")
        let pdf = try pdfPages(doc)
        let margin = doc.pageSetup.margins.left
        let fruit = try bounds(of: "Fruit", on: 0, in: pdf)
        let apples = try bounds(of: "Apples", on: 0, in: pdf)
        XCTAssertEqual(fruit.minX, margin + 36, accuracy: 1.5)
        XCTAssertEqual(apples.minX, margin + 72, accuracy: 1.5)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let bullets = pdf.findString("•", withOptions: []).map { $0.bounds(for: page) }
        XCTAssertTrue(
            bullets.contains { abs($0.minX - (margin + 18)) < 1.5 && abs($0.midY - fruit.midY) < 3 },
            "the bullet before Fruit, at the hanging indent: \(bullets)")
        let numbers = pdf.findString("1.", withOptions: []).map { $0.bounds(for: page) }
        let prepare = try bounds(of: "Prepare", on: 0, in: pdf)
        XCTAssertTrue(numbers.contains { abs($0.midY - prepare.midY) < 3 && $0.maxX <= prepare.minX })
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

    /// Backlog 7: each section prints its own headers and footers, or those it inherits.
    func testEachSectionPrintsItsOwnHeadersAndFooters() throws {
        let pdf = try pdfPages(try open("16-section-headers.docx"))
        XCTAssertEqual(pdf.pageCount, 5)
        let expected = [
            ("Section one, page one.", "Section one first-page header", nil),
            ("Section one, page two.", "Section one header", "Section one footer"),
            ("Section two", "Section one header", "Section one footer"),
            ("Section three", "Section three header", "Section one footer"),
            ("Final section.", "Final section header", "Final section footer"),
        ]
        for (i, (body, header, footer)) in expected.enumerated() {
            let page = pageText(pdf, i)
            XCTAssertTrue(page.contains(body), "page \(i + 1): \(page)")
            let lines = page.split(whereSeparator: \.isNewline).map(String.init)
            XCTAssertEqual(lines.filter { $0.hasSuffix("header") }, [header], "page \(i + 1)")
            XCTAssertEqual(lines.filter { $0.hasSuffix("footer") }, footer.map { [$0] } ?? [], "page \(i + 1)")
        }
    }

    /// Backlog 8: a header reaching below the top margin pushes the body down, and a footer above the bottom margin
    /// pushes it up, unless the margin is negative (Word's "exactly").
    func testTallHeadersAndFootersPushTheBodyAway() throws {
        let header = "Libretilla fixture — running header"
        let doc = try open("07-header-footer.docx")
        var setup = doc.pageSetup
        (setup.top, setup.bottom, setup.header, setup.footer) = (360, 360, 720, 720)  // ¼″ margins, ½″ distances
        doc.setPageSetup(setup)
        var pdf = try pdfPages(doc)
        let height = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).height
        let headerBox = try bounds(of: header, on: 0, in: pdf)
        let body = try bounds(of: "Header and footer", on: 0, in: pdf)
        XCTAssertLessThanOrEqual(body.maxY, headerBox.minY, "the body starts below the header")
        XCTAssertGreaterThan(height - body.maxY, 36 + 6, "well below the ¼″ margin")
        // The footer: the body's last line on the page ends above it.
        let page = try XCTUnwrap(pdf.page(at: 0))
        let footerBox = try bounds(of: "Page 1", on: 0, in: pdf)
        let lines = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
            .selectionsByLine().map { $0.bounds(for: page) }
        let lowest = try XCTUnwrap(
            lines.filter { $0.minY > footerBox.maxY + 0.5 || $0.maxY < footerBox.minY }.map(\.minY).min())
        XCTAssertGreaterThanOrEqual(lowest, footerBox.maxY, "the body ends above the footer")
        XCTAssertGreaterThan(lowest, 18 + 6, "well above the ¼″ margin")

        // Negative: exactly ¼″, header or not.
        setup.top = -360
        doc.setPageSetup(setup)
        pdf = try pdfPages(doc)
        let exact = try bounds(of: "Header and footer", on: 0, in: pdf)
        XCTAssertGreaterThan(exact.maxY, body.maxY + 10, "the body starts at the ¼″ margin, over the header")
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
    func openHeaderFooterSheet(_ doc: LibretillaDocument) throws -> HeaderFooterSheet {
        let editor = try XCTUnwrap(doc.editor)
        editor.editHeaderAndFooter(nil)
        return try XCTUnwrap(editor.headerFooterEditor)
    }

    /// Types `text` at the end of the sheet's header or footer.
    func type(_ text: String, in kind: HeadersFooters.Kind, _ sheet: HeaderFooterSheet) throws {
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
            editor.insertDocumentPageBreak(nil)
        }
        XCTAssertEqual(try pdfPages(doc).pageCount, 3)

        let sheet = try openHeaderFooterSheet(doc)
        try type("Page ", in: .footer, sheet)
        sheet.insert(.page)
        try type(" of ", in: .footer, sheet)
        sheet.insert(.pageCount)
        sheet.done()

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
        XCTAssertFalse(sheet.differentFirstPage)
        sheet.differentFirstPage = true
        sheet.choose(.first)
        XCTAssertEqual(sheet.slot, .first)
        XCTAssertEqual(sheet.textViews[.header]?.string, "\n", "a new, empty first-page header")
        try type("Cover", in: .header, sheet)
        sheet.done()

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
        XCTAssertTrue(sheet.differentFirstPage)
        let footer = try XCTUnwrap(sheet.textViews[.footer]?.textStorage)
        var chips = 0
        footer.enumerateAttribute(.attachment, in: NSRange(location: 0, length: footer.length)) { v, _, _ in
            if v != nil { chips += 1 }
        }
        XCTAssertEqual(chips, 2, "page number and page count")
        XCTAssertEqual(sheet.textViews[.header]?.string, "Odd page header\n")

        try type(" edited", in: .header, sheet)
        sheet.cancel()
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.headersFooters.stories[.init(.header, .default)]?.body.plainText, "Odd page header")
    }

    func testSheetEditKeepsOtherPartsByteForByte() throws {
        let doc = try open("14-headers-footers.docx")
        let before = try OOXMLCodec().read(try Data(contentsOf: try XCTUnwrap(doc.fileURL)))
        let sheet = try openHeaderFooterSheet(doc)
        try type(" (edited)", in: .header, sheet)
        sheet.done()
        let saved = try saved(doc)
        XCTAssertEqual(
            saved.headersFooters.stories[.init(.header, .default)]?.body.plainText, "Odd page header (edited)")
        for name in ["word/header1.xml", "word/header3.xml", "word/footer1.xml", "word/footer2.xml"] {
            XCTAssertEqual(saved.package[name], before.package[name], name)
        }
    }
}
