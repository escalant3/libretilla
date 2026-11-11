import AppKit
import LibretillaDocx

/// Typing into table cells (backlog 15, ADR 0008): a click in a cell opens `TableCellEditor` over it.
extension EditorViewController {
    /// The cell under `point` (text view coordinates), if a table is there and the cell can be typed into: the
    /// table's start and the cell.
    func tableCell(at point: NSPoint) -> (tableLocation: Int, position: TableModel.CellPosition)? {
        guard let storage = textView.textStorage else { return nil }
        let index = textView.characterIndexForInsertion(at: point)
        for at in [index, index - 1] where at >= 0 && at < storage.length {
            guard let row = storage.attribute(.libretillaTableRow, at: at, effectiveRange: nil) as? Int,
                let found = table(at: at), let frame = pictureFrame(at: at), frame.contains(point),
                let model = TableModel(xml: found.box.block.xml)
            else { continue }
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            guard
                let cell = bridge.cellGeometry(of: model)[row].first(where: { $0.frame.contains(local) }),
                model.canEditInPlace(cell.position)
            else { return nil }
            return (found.range.location, cell.position)
        }
        return nil
    }

    /// Opens the cell under `point` for typing, with the caret where it was clicked. False if there's no such cell.
    @discardableResult
    func beginCellEditing(at point: NSPoint) -> Bool {
        guard textView.isEditable, let (location, position) = tableCell(at: point) else { return false }
        return beginCellEditing(tableLocation: location, position: position, caretAt: point)
    }

    @discardableResult
    func beginCellEditing(tableLocation: Int, position: TableModel.CellPosition, caretAt point: NSPoint? = nil)
        -> Bool
    {
        if let current = cellEditor {
            guard current.tableLocation != tableLocation else {
                return false
            }
            endCellEditing()
        }
        guard textView.isEditable,
            let editor = TableCellEditor(editor: self, tableLocation: tableLocation, position: position)
        else { return false }
        cellEditor = editor
        textView.addSubview(editor.textView)
        editor.place()
        view.window?.makeFirstResponder(editor.textView)
        if let point {
            let local = editor.textView.convert(point, from: textView)
            editor.textView.setSelectedRange(
                NSRange(location: editor.textView.characterIndexForInsertion(at: local), length: 0))
        }
        scheduleSelectionUpdate()
        return true
    }

    /// Leaves the cell being typed in: its table's changes become one undoable step.
    func endCellEditing(caretAfterTable: Bool = false) {
        guard let editor = cellEditor else { return }
        cellEditor = nil
        editor.textView.removeFromSuperview()
        editor.finish()
        if let found = table(at: editor.tableLocation) {
            let caret =
                caretAfterTable ? min(NSMaxRange(found.range) + 1, textView.string.utf16.count) : found.range.location
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        view.window?.makeFirstResponder(textView)
        scheduleSelectionUpdate()
    }

    /// Shows the table at `location` as `xml` (or as `text`), without an undo step: the cell editor's live changes.
    func showTable(_ xml: Data, at location: Int, text: NSAttributedString? = nil) {
        guard let storage = textView.textStorage, let found = table(at: location) else { return }
        let replacement: NSAttributedString
        if let text {
            replacement = text
        } else {
            guard let block = OpaqueBlock(xml: xml, leadingTrivia: found.box.block.leadingTrivia),
                let table = bridge.tableText(block, leadingBlocks: found.box.leadingBlocks)
            else { return }
            replacement = table
        }
        let whole = TableCellEditor.wholeRange(found.range, in: storage)
        withoutReconciling {
            storage.beginEditing()
            storage.replaceCharacters(in: whole, with: replacement)
            storage.endEditing()
        }
    }
}
