import AppKit
import LibretillaDocx

/// Typing into a table cell (backlog 15, ADR 0008). Tables are drawn as row pictures (ADR 0006), so a cell is edited
/// in a text view laid exactly over it, holding the cell's paragraphs with their Word formatting. Each change is
/// written into the table's XML at once (so the page and every save show it); leaving the table makes it one
/// undoable "Typing" step. While typing, Undo works inside the cell.
@MainActor
final class TableCellEditor: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate,
    @preconcurrency NSTextContentStorageDelegate
{
    let textView: CellTextView
    /// The table: where it starts in the editor's text, its XML when editing began and now.
    let tableLocation: Int
    let originalXML: Data
    let originalText: NSAttributedString
    private(set) var xml: Data
    private(set) var position: TableModel.CellPosition
    /// The cell's paragraphs as loaded (the base its edits are written against).
    private var body: DocumentBody
    private let undo = UndoManager()
    private weak var editor: EditorViewController?
    /// Whether the document was marked edited for this table's changes (balanced when they become one step).
    private var markedEdited = false
    /// Moving between cells ends one cell's editing without ending the table's.
    private var switching = false
    /// While a cell loads, its storage changes aren't edits.
    private var loading = false

    init?(editor: EditorViewController, tableLocation: Int, position: TableModel.CellPosition) {
        guard let storage = editor.textView.textStorage, let found = editor.table(at: tableLocation),
            let model = TableModel(xml: found.box.block.xml), let body = model.cellBody(position)
        else { return nil }
        self.editor = editor
        self.tableLocation = found.range.location
        originalXML = found.box.block.xml
        xml = originalXML
        originalText = storage.attributedSubstring(from: Self.wholeRange(found.range, in: storage))
        self.position = position
        self.body = body
        textView = CellTextView(usingTextLayoutManager: true)
        super.init()
        textView.cellEditor = self
        textView.textLayoutManager?.delegate = ListMarkerLayout.shared
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = editor.textView.isContinuousSpellCheckingEnabled
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        // The editor keeps the cell's size (the row grows with the text); TextKit would add a line below.
        textView.isVerticallyResizable = false
        textView.drawsBackground = true
        textView.focusRingType = .none
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.textContentStorage?.delegate = self
        textView.setAccessibilityLabel(String(localized: "Table cell"))
        load(position)
    }

    /// The table's rows and the line break after them (what `replaceTable` replaces).
    static func wholeRange(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
    }

    private var model: TableModel? { TableModel(xml: xml) }

    /// Shows cell `position`'s paragraphs, laid over it.
    private func load(_ position: TableModel.CellPosition) {
        guard let editor, let body = model?.cellBody(position) else { return }
        self.position = position
        self.body = body
        loading = true
        textView.textStorage?.setAttributedString(editor.bridge.attributedString(for: body))
        loading = false
        undo.removeAllActions()
        place()
    }

    /// Puts the text view over the cell's text.
    func place() {
        guard let editor, let model, let geometry = cellGeometry(model),
            let row = editor.pictureFrame(at: tableLocation + 2 * position.row)
        else { return }
        let frame = geometry.textFrame.offsetBy(dx: row.minX, dy: row.minY)
        textView.backgroundColor = geometry.fill ?? editor.textView.backgroundColor
        // The row is laid out again on every change, so the cell's room is exactly the height of its text.
        textView.frame = frame
    }

    private func cellGeometry(_ model: TableModel) -> TableCellGeometry? {
        guard let editor else { return nil }
        return editor.bridge.cellGeometry(of: model).flatMap { $0 }.first { $0.position == position }
    }

    /// Each paragraph shown with the spacing the table gives it when drawn (display only: its Word formatting, and
    /// what's saved, are the paragraph's own).
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange)
        -> NSTextParagraph?
    {
        guard let editor, let model, let storage = textContentStorage.textStorage, NSMaxRange(range) <= storage.length
        else { return nil }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        guard text.length > 0,
            let shown = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return nil }
        let properties = AttributedStringBridge.paragraphFormatOf(storage, range)?.properties ?? ParagraphProperties()
        let style = editor.bridge.cellParagraphStyle(shown, for: properties, in: model)
        // The last paragraph has no space after: the cell ends with its text.
        if NSMaxRange(range) >= storage.length, let last = style.mutableCopy() as? NSMutableParagraphStyle {
            last.paragraphSpacing = 0
            text.addAttribute(.paragraphStyle, value: last, range: NSRange(location: 0, length: text.length))
        } else {
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        }
        return NSTextParagraph(attributedString: text)
    }

    // MARK: Editing

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    /// Each change (typing, formatting, undo) goes into the table at once: redrawn on the page, and in what a save
    /// writes. AppKit's own tools (paste, the Font panel) change only how text looks: work out its Word formatting
    /// first, as the editor does.
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !loading, editedRange.location != NSNotFound, let editor else { return }
        editor.bridge.reconcile(textStorage, range: editedRange)
        sync()
    }

    private func sync() {
        guard let editor, let storage = textView.textStorage, let model else { return }
        let edited = editor.bridge.body(from: storage, base: body).body
        guard let newXML = model.replacingCell(position, with: edited) else { return }
        xml = newXML
        body = edited
        editor.showTable(xml, at: tableLocation)
        if !markedEdited {
            editor.document?.updateChangeCount(.changeDone)
            markedEdited = true
        }
        place()
    }

    /// Typed text never joins a link or field, as in the document.
    func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = newTypingAttributes
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        return attrs
    }

    /// Content Libretilla keeps whole (links with fields, pictures, …) is edited whole or not at all.
    func textView(
        _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?
    ) -> Bool {
        guard text != nil, let storage = textView.textStorage else { return true }
        return EditorViewController.editIsAllowed(range, in: storage)
    }

    func textViewDidChangeSelection(_ notification: Notification) { editor?.scheduleSelectionUpdate() }

    /// Tab and Shift-Tab move between cells; Escape leaves the table.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): move(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): move(by: -1)
        case #selector(NSResponder.cancelOperation(_:)): editor?.endCellEditing()
        default: return false
        }
        return true
    }

    /// Edits the next (or previous) cell that can be typed into; past the last one, leaves the table.
    func move(by step: Int) {
        guard let model else { return }
        let cells = model.rows.indices.flatMap { r in
            model.rows[r].cells.indices.map { TableModel.CellPosition(row: r, cell: $0) }
        }.filter(model.canEditInPlace)
        guard let i = cells.firstIndex(of: position), cells.indices.contains(i + step) else {
            editor?.endCellEditing(caretAfterTable: step > 0)
            return
        }
        switching = true
        load(cells[i + step])
        textView.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        switching = false
    }

    /// Clicking elsewhere leaves the table.
    func textDidEndEditing(_ notification: Notification) {
        guard !switching else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor, editor.cellEditor === self,
                self.textView.window?.firstResponder !== self.textView
            else { return }
            editor.endCellEditing()
        }
    }

    /// Done: the table goes back to how it was, then takes all the changes as one undoable edit.
    func finish() {
        guard let editor else { return }
        if markedEdited { editor.document?.updateChangeCount(.changeUndone) }
        guard xml != originalXML else { return }
        editor.showTable(originalXML, at: tableLocation, text: originalText)
        guard let found = editor.table(at: tableLocation) else { return }
        editor.replaceTable(found.range, box: found.box, with: xml, actionName: String(localized: "Typing"))
    }
}

/// The text view a table cell is typed in.
final class CellTextView: NSTextView {
    weak var cellEditor: TableCellEditor?
}
