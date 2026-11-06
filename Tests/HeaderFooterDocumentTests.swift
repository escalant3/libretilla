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
}
