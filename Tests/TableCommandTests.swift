import AppKit
import CartillaDocx
import XCTest

@testable import Cartilla

/// Tables (ADR 0006) through the real editor, undo and save path.
@MainActor
final class TableCommandTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!
    var doc: CartillaDocument!
    var editor: EditorViewController { doc.editor! }
    var tv: CartillaTextView { editor.textView }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cartilla-tables-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        doc = try CartillaDocument(contentsOf: url, ofType: CartillaDocument.docxType)
        doc.makeWindowControllers()
    }

    func saved() throws -> DocxDocument {
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

    func tables(_ doc: DocxDocument) -> [TableModel] {
        doc.body.blocks.compactMap {
            if case .opaque(let o) = $0, o.kind == "w:tbl" { TableModel(xml: o.xml) } else { nil }
        }
    }

    var firstRow: Int { (tv.string as NSString).range(of: "\u{FFFC}").location }

    func testEditingCellsIsSavedAndUndoable() throws {
        try open("04-tables.docx")
        let found = try XCTUnwrap(editor.table(at: firstRow))
        XCTAssertEqual(found.row, 0)
        let model = try XCTUnwrap(TableModel(xml: found.box.block.xml))
        editor.replaceTable(found.range, box: found.box, with: model.replacingTexts([.init(row: 2, cell: 2): "Juicy"]))
        XCTAssertEqual(try tables(saved()).first?.rows[2].cells[2].text, "Juicy")
        XCTAssertTrue(try saved().body.plainText.contains("After the tables."))

        doc.undoManager?.undo()
        XCTAssertEqual(try tables(saved()).first?.rows[2].cells[2].text, "Ripe")
        XCTAssertEqual(try tables(saved()).count, 2)
    }

    func testTypingInsideATableIsRefused() throws {
        try open("04-tables.docx")
        let before = tv.string
        let between = firstRow + 1  // after the first row's character, before the line break inside the table
        XCTAssertFalse(tv.shouldChangeText(in: NSRange(location: between, length: 0), replacementString: "x"))
        XCTAssertEqual(tv.string, before)
    }

    func testInsertTableMakesATableGridTable() throws {
        doc = CartillaDocument()
        doc.makeWindowControllers()
        tv.insertText("Before", replacementRange: NSRange(location: 0, length: 0))
        editor.insertTable(rows: 2, columns: 3)
        let saved = try saved()
        let table = try XCTUnwrap(tables(saved).first)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.columns.count, 3)
        XCTAssertEqual(table.columns.reduce(0, +), Double(PageSetup.a4.textWidth), accuracy: 0.5)
        XCTAssertEqual(table.properties.styleId, saved.styles.styleId(named: "Table Grid", type: "table"))
        XCTAssertNotNil(table.properties.styleId)
        // "Before" stays its own paragraph, and a paragraph follows the table (Word needs one).
        XCTAssertTrue(saved.body.plainText.hasPrefix("Before\n"))
        guard
            case .paragraph = saved.body.blocks.last(where: {
                if case .opaque(let o) = $0 { !o.isSectionProperties } else { true }
            })
        else {
            return XCTFail("the body must end with a paragraph")
        }
    }

    func testTheEditorSheetCommitsItsFields() throws {
        try open("04-tables.docx")
        let found = try XCTUnwrap(editor.table(at: firstRow))
        let sheet = try XCTUnwrap(TableEditorController(xml: found.box.block.xml, row: 1))
        var result: Data?
        sheet.onDone = { result = $0 }
        sheet.fields[.init(row: 1, cell: 0)]?.stringValue = "Green apples"
        sheet.addRow(nil)
        sheet.done(nil)
        let model = try XCTUnwrap(result.flatMap(TableModel.init(xml:)))
        XCTAssertEqual(model.rows[1].cells[0].text, "Green apples")
        XCTAssertEqual(model.rows.count, 8)
    }
}
