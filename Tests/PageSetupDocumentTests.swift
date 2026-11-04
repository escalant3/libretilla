import AppKit
import CartillaDocx
import PDFKit
import XCTest

@testable import Cartilla

/// M3 page setup and PDF export through the real document, editor and save path.
@MainActor
final class PageSetupDocumentTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cartilla-pages-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws -> CartillaDocument {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        let doc = try CartillaDocument(contentsOf: url, ofType: CartillaDocument.docxType)
        doc.makeWindowControllers()
        return doc
    }

    func saved(_ doc: CartillaDocument) throws -> DocxDocument {
        let url = scratch.appendingPathComponent("\(UUID()).docx")
        let done = expectation(description: "saved")
        var failure: Error?
        doc.save(to: url, ofType: CartillaDocument.docxType, for: .saveToOperation) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return try OOXMLCodec().read(try Data(contentsOf: url))
    }

    func pdfPages(_ doc: CartillaDocument) throws -> PDFDocument {
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
            doc.editor?.textView.string.split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " "))
        let lastPage = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
        XCTAssertTrue(
            lastPage.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(lastWords),
            "last page ends with \(lastWords)")
    }

    func testPDFOfALandscapeDocumentIsWide() throws {
        let doc = try open("01-plain.docx")
        var setup = doc.pageSetup
        (setup.width, setup.height, setup.isLandscape) = (setup.height, setup.width, true)
        doc.setPageSetup(setup)
        let box = try XCTUnwrap(try pdfPages(doc).page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.size, CGSize(width: 792, height: 612))
    }
}
