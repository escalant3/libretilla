import AppKit
import LibretillaDocx

/// Tables (ADR 0006): Insert ▸ Table…, Format ▸ Edit Table…, double-click to edit.
extension EditorViewController {
    /// The table at `location` (a row character, or the line break after a row): its whole range (rows and
    /// the line breaks between them), its block, and the row.
    func table(at location: Int) -> (range: NSRange, box: OpaqueBlockBox, row: Int)? {
        guard let storage = textView.textStorage else { return nil }
        for at in [location, location - 1] where at >= 0 && at < storage.length {
            guard
                let row = storage.attribute(.libretillaTableRow, at: at, effectiveRange: nil) as? Int
                    ?? (at > 0 ? storage.attribute(.libretillaTableRow, at: at - 1, effectiveRange: nil) as? Int : nil),
                let box = storage.attribute(.libretillaBlock, at: at, effectiveRange: nil) as? OpaqueBlockBox
                    ?? (at > 0
                        ? storage.attribute(.libretillaBlock, at: at - 1, effectiveRange: nil) as? OpaqueBlockBox : nil)
            else { continue }
            var range = NSRange()
            let probe = storage.attribute(.libretillaBlock, at: at, effectiveRange: nil) != nil ? at : at - 1
            _ = storage.attribute(
                .libretillaBlock, at: probe, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length))
            return (range, box, row)
        }
        return nil
    }

    var tableAtSelection: (range: NSRange, box: OpaqueBlockBox, row: Int)? {
        table(at: textView.selectedRange().location)
    }

    @objc func editTable(_ sender: Any?) {
        guard let found = tableAtSelection else { return NSSound.beep() }
        openTableEditor(found)
    }

    func openTableEditor(_ found: (range: NSRange, box: OpaqueBlockBox, row: Int)) {
        guard textView.isEditable, let window = view.window else { return NSSound.beep() }
        guard let editor = TableEditorController(xml: found.box.block.xml, row: found.row) else {
            return NSSound.beep()
        }
        let box = found.box
        editor.onDone = { [weak self] xml in
            guard let self, let current = self.range(of: box) else { return }
            self.replaceTable(current, box: box, with: xml)
        }
        tableEditor = editor
        window.beginSheet(editor.window!) { [weak self] _ in
            self?.tableEditor = nil
            self.map { $0.view.window?.makeFirstResponder($0.textView) }
        }
    }

    /// Where the table with this block is now (edits elsewhere may have moved it).
    private func range(of box: OpaqueBlockBox) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.libretillaBlock, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            if (v as AnyObject?) === box {
                found = found.map { NSUnionRange($0, r) } ?? r
            }
        }
        return found
    }

    /// Replaces a table with edited XML as one undoable edit (its rows and the line break after them).
    func replaceTable(_ range: NSRange, box: OpaqueBlockBox, with xml: Data) {
        guard let storage = textView.textStorage,
            let block = OpaqueBlock(xml: xml, leadingTrivia: box.block.leadingTrivia),
            let text = bridge.tableText(block, leadingBlocks: box.leadingBlocks)
        else { return NSSound.beep() }
        let whole = NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
        guard textView.shouldChangeText(in: whole, replacementString: text.string) else { return }
        storage.replaceCharacters(in: whole, with: text)
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Edit Table"))
    }

    /// Insert ▸ Table…: asks for the size, then inserts an empty table in "Table Grid" style at the caret
    /// (after the current paragraph's text before the caret, which stays a paragraph of its own).
    @objc func insertTable(_ sender: Any?) {
        guard textView.isEditable, let window = view.window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = String(localized: "Insert Table")
        let rows = NSTextField(string: "3")
        let columns = NSTextField(string: "3")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Rows")), rows],
            [NSTextField(labelWithString: String(localized: "Columns")), columns],
        ])
        grid.column(at: 1).width = 60
        grid.frame = NSRect(x: 0, y: 0, width: 160, height: 56)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Insert"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = rows
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                let r = min(100, max(1, rows.integerValue))
                let c = min(20, max(1, columns.integerValue))
                self.insertTable(rows: r, columns: c)
                self.view.window?.makeFirstResponder(self.textView)
            }
        }
    }

    func insertTable(rows: Int, columns: Int) {
        guard let storage = textView.textStorage else { return }
        let style = document?.tableStyleId(named: "Table Grid")
        let xml = TableModel.newTable(rows: rows, columns: columns, width: Double(pageSetup.textWidth), styleId: style)
        guard let block = OpaqueBlock(xml: xml), let table = bridge.tableText(block, leadingBlocks: []) else {
            return NSSound.beep()
        }
        // Tables are paragraph-level: start on a new line unless the caret is already at a line start.
        let at = textView.selectedRange()
        let ns = storage.string as NSString
        let lineStart = at.location == 0 || ns.character(at: at.location - 1) == 0x0A
        let insertion = NSMutableAttributedString()
        if !lineStart { insertion.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes)) }
        insertion.append(table)
        textView.insertText(insertion, replacementRange: at)
        textView.undoManager?.setActionName(String(localized: "Insert Table"))
    }
}
