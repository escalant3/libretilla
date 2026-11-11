import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// Tables (ADR 0006) through the real editor, undo and save path.
@MainActor
final class TableCommandTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!
    var doc: LibretillaDocument!
    var editor: EditorViewController { doc.editor! }
    var tv: LibretillaTextView { editor.textView }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-tables-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        makeWindow(for: doc)
    }

    func saved() throws -> DocxDocument {
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

    /// The width the first table is drawn at (its first row's attachment).
    var firstTableWidth: CGFloat? {
        (tv.textStorage?.attribute(.attachment, at: firstRow, effectiveRange: nil) as? NSTextAttachment)?.bounds.width
    }

    /// Backlog 20: a page setup change refits tables at once, without editing the document.
    func testTablesFollowAPageSetupChange() throws {
        try open("04-tables.docx")
        let wide = try XCTUnwrap(firstTableWidth)
        func tableXML() throws -> [Data] {
            try saved().body.blocks.compactMap { if case .opaque(let o) = $0, o.kind == "w:tbl" { o.xml } else { nil } }
        }
        let before = try tableXML()
        var setup = doc.pageSetup
        setup.left += 4 * 1440  // 4″ more margin: the column is narrower than the table
        doc.setPageSetup(setup)
        let narrow = try XCTUnwrap(firstTableWidth)
        XCTAssertLessThan(narrow, wide)
        XCTAssertEqual(narrow, setup.textWidth, accuracy: 0.5, "scaled to the new text column")
        XCTAssertNotNil(editor.table(at: firstRow), "still a table")
        XCTAssertEqual(try tableXML(), before, "display only")

        doc.undoManager?.undo()
        XCTAssertEqual(try XCTUnwrap(firstTableWidth), wide, accuracy: 0.5)
        XCTAssertEqual(try tableXML(), before)
    }

    func testTypingInsideATableIsRefused() throws {
        try open("04-tables.docx")
        let before = tv.string
        let between = firstRow + 1  // after the first row's character, before the line break inside the table
        XCTAssertFalse(tv.shouldChangeText(in: NSRange(location: between, length: 0), replacementString: "x"))
        XCTAssertEqual(tv.string, before)
    }

    func testInsertTableMakesATableGridTable() throws {
        doc = LibretillaDocument()
        makeWindow(for: doc)
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
        let sheet = try XCTUnwrap(TableEditorSheet(xml: found.box.block.xml, row: 1))
        var result: Data?
        sheet.onDone = { result = $0 }
        sheet.texts[.init(row: 1, cell: 0)] = "Green apples"
        sheet.addRow()
        sheet.done()
        let model = try XCTUnwrap(result.flatMap(TableModel.init(xml:)))
        XCTAssertEqual(model.rows[1].cells[0].text, "Green apples")
        XCTAssertEqual(model.rows.count, 8)
    }

    // MARK: Typing into cells (backlog 15)

    /// Starts typing in cell (row, cell) of the first table, with its text selected.
    func editCell(_ row: Int, _ cell: Int) throws -> NSTextView {
        XCTAssertTrue(editor.beginCellEditing(tableLocation: firstRow, position: .init(row: row, cell: cell)))
        let cellView = try XCTUnwrap(editor.cellEditor?.textView)
        XCTAssertTrue(cellView.superview === tv, "laid over the page")
        return cellView
    }

    func cellText(_ row: Int, _ cell: Int) throws -> String? { try tables(saved()).first?.rows[row].cells[cell].text }

    func testTypingIntoACellIsSavedAtOnceAndUndoneAsOneStep() throws {
        try open("04-tables.docx")
        let cell = try editCell(1, 2)
        XCTAssertEqual(cell.string, "Green\n")
        cell.setSelectedRange(NSRange(location: 5, length: 0))
        cell.insertText(" and crisp", replacementRange: cell.selectedRange())
        XCTAssertEqual(try cellText(1, 2), "Green and crisp", "a save while typing has it")
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(try cellText(1, 1), "3", "other cells untouched")

        cell.undoManager?.undo()
        XCTAssertEqual(cell.string, "Green\n", "undo inside the cell while typing")
        XCTAssertEqual(try cellText(1, 2), "Green")
        cell.undoManager?.redo()
        XCTAssertEqual(cell.string, "Green and crisp\n")

        editor.endCellEditing()
        XCTAssertNil(editor.cellEditor)
        XCTAssertNil(cell.superview)
        XCTAssertEqual(try cellText(1, 2), "Green and crisp")
        XCTAssertEqual(doc.undoManager?.undoActionName, "Typing")
        doc.undoManager?.undo()
        XCTAssertEqual(try cellText(1, 2), "Green", "one step for the whole table")
        doc.undoManager?.redo()
        XCTAssertEqual(try cellText(1, 2), "Green and crisp")
    }

    func testFormattingCommandsActOnTheCell() throws {
        try open("04-tables.docx")
        let cell = try editCell(2, 0)  // "Pears"
        cell.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertFalse(editor.currentFormat.bold)
        editor.toggleBold(nil)
        XCTAssertTrue(editor.currentFormat.bold, "the format bar shows the cell's")
        editor.endCellEditing()
        let xml = String(decoding: try XCTUnwrap(try tables(saved()).first?.xml), as: UTF8.self)
        XCTAssertTrue(xml.contains("<w:b/></w:rPr><w:t>Pears</w:t>"), xml)
        XCTAssertFalse(tv.textStorage?.string.contains("Pears") ?? true, "the body text is untouched")
    }

    func testTabMovesBetweenCellsAndLeavesAfterTheLast() throws {
        try open("04-tables.docx")
        let first = try editCell(0, 2)  // "Notes"
        XCTAssertTrue(first.delegate?.textView?(first, doCommandBy: #selector(NSResponder.insertTab(_:))) ?? false)
        XCTAssertEqual(editor.cellEditor?.position, .init(row: 1, cell: 0))
        XCTAssertEqual(editor.cellEditor?.textView.string, "Apples\n")
        _ = first.delegate?.textView?(first, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(editor.cellEditor?.position, .init(row: 0, cell: 2))
        // The last cell that can be typed into ("d"), then out of the table.
        editor.endCellEditing()
        let last = try editCell(6, 2)
        _ = last.delegate?.textView?(last, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertNil(editor.cellEditor)
        XCTAssertGreaterThan(tv.selectedRange().location, firstRow + 12, "the caret after the table")
    }

    func testAClickInACellStartsTyping() throws {
        try open("04-tables.docx")
        let row = try XCTUnwrap(editor.pictureFrame(at: firstRow + 2))  // "Apples" row
        let model = try XCTUnwrap(editor.table(at: firstRow).flatMap { TableModel(xml: $0.box.block.xml) })
        let cell = try XCTUnwrap(editor.bridge.cellGeometry(of: model)[1].first { $0.position.cell == 2 })
        let point = NSPoint(x: row.minX + cell.textFrame.midX, y: row.minY + cell.textFrame.midY)
        XCTAssertTrue(editor.textView(tv, clickedAt: point))
        XCTAssertEqual(editor.cellEditor?.position, .init(row: 1, cell: 2))
        // Links, pictures and page breaks can't go in a cell.
        let link = NSMenuItem(title: "Link", action: #selector(EditorViewController.editLink(_:)), keyEquivalent: "")
        XCTAssertFalse(editor.validateMenuItem(link))
        editor.endCellEditing()
        XCTAssertFalse(editor.textView(tv, clickedAt: NSPoint(x: 5, y: 5)), "not in a table")
    }
}
