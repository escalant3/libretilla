import AppKit
import LibretillaDocx

/// The cell editor sheet (ADR 0006): a table's cells as a grid of text fields, plus rows and columns.
/// Works on the table's XML; `onDone` gets the edited XML (only if something changed).
final class TableEditorController: NSWindowController, NSTextFieldDelegate {
    private let original: Data
    private var xml: Data
    private var model: TableModel
    private(set) var fields: [TableModel.CellPosition: NSTextField] = [:]
    private var positions: [ObjectIdentifier: TableModel.CellPosition] = [:]
    private var focused: TableModel.CellPosition
    private let scrollView = NSScrollView()
    private var columnButtons: [NSButton] = []
    private var removeRowButton: NSButton!
    var onDone: ((Data) -> Void)?

    init?(xml: Data, row: Int) {
        guard let model = TableModel(xml: xml) else { return nil }
        original = xml
        self.xml = xml
        self.model = model
        focused = TableModel.CellPosition(row: min(max(0, row), model.rows.count - 1), cell: 0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true)
        window.title = String(localized: "Edit Table")
        window.contentMinSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        buildWindow()
        rebuildGrid()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        return b
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        let addRow = button(String(localized: "Add Row"), #selector(addRow(_:)))
        removeRowButton = button(String(localized: "Remove Row"), #selector(removeRow(_:)))
        let addColumn = button(String(localized: "Add Column"), #selector(addColumn(_:)))
        let removeColumn = button(String(localized: "Remove Column"), #selector(removeColumn(_:)))
        columnButtons = [addColumn, removeColumn]
        let cancel = button(String(localized: "Cancel"), #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = button(String(localized: "Done"), #selector(done(_:)))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addRow, removeRowButton, addColumn, removeColumn, spacer, cancel, done])
        buttons.orientation = .horizontal

        let hint = NSTextField(labelWithString: String(localized: "Press Option-Return for a new line in a cell."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [scrollView, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    /// Lays the cells out: one column per grid column, spans merged, merged-away cells shown disabled.
    private func rebuildGrid() {
        fields = [:]
        positions = [:]
        let columnCount = max(1, model.columns.count)
        let grid = NSGridView(numberOfColumns: columnCount, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        let total = max(1, model.columns.reduce(0, +))
        for (r, row) in model.rows.enumerated() {
            var views: [NSView] = Array(repeating: NSGridCell.emptyContentView, count: columnCount)
            for (c, cell) in row.cells.enumerated() where cell.gridStart < columnCount {
                let field = NSTextField(string: cell.verticalMerge == .continue ? "" : cell.text)
                field.usesSingleLineMode = false
                field.cell?.wraps = true
                field.cell?.isScrollable = false
                field.lineBreakMode = .byWordWrapping
                field.isEditable = cell.isEditable && cell.verticalMerge != .continue
                field.isEnabled = field.isEditable
                if cell.verticalMerge == .continue {
                    field.placeholderString = String(localized: "(merged)")
                } else if !cell.isEditable {
                    field.toolTip = String(localized: "This cell has content the editor can't change.")
                }
                field.delegate = self
                let pos = TableModel.CellPosition(row: r, cell: c)
                fields[pos] = field
                positions[ObjectIdentifier(field)] = pos
                views[cell.gridStart] = field
            }
            grid.addRow(with: views)
            for cell in row.cells where cell.span > 1 && cell.gridStart + cell.span <= columnCount {
                grid.mergeCells(
                    inHorizontalRange: NSRange(location: cell.gridStart, length: cell.span),
                    verticalRange: NSRange(location: r, length: 1))
            }
            if row.isHeader {
                for case let field as NSTextField in views {
                    field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                }
            }
        }
        // Column widths in proportion to the table's, at least 90 points each.
        for c in 0..<columnCount {
            let share = c < model.columns.count ? model.columns[c] / total : 1 / Double(columnCount)
            grid.column(at: c).width = max(90, CGFloat(share) * 540)
        }
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 8),
            grid.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            flipped.trailingAnchor.constraint(greaterThanOrEqualTo: grid.trailingAnchor, constant: 8),
            flipped.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
        ])
        flipped.frame.size = grid.fittingSize.applying(.init(translationX: 16, y: 16))
        flipped.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = flipped
        flipped.frame.size = NSSize(width: grid.fittingSize.width + 16, height: grid.fittingSize.height + 16)

        for b in columnButtons { b.isEnabled = model.isSimpleGrid }
        removeRowButton.isEnabled = model.rows.count > 1
        if focused.row >= model.rows.count { focused.row = model.rows.count - 1 }
        if let field = fields[focused]
            ?? fields.first(where: { $0.key.row == focused.row && $0.value.isEditable })?.value
        {
            window?.makeFirstResponder(field)
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, let pos = positions[ObjectIdentifier(field)] { focused = pos }
    }

    /// Option-Return types a line break inside a cell (Return ends editing, as in any text field).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    /// The table with the text currently in the fields.
    private func commitTexts() {
        window?.makeFirstResponder(nil)
        var texts: [TableModel.CellPosition: String] = [:]
        for (pos, field) in fields where field.isEditable { texts[pos] = field.stringValue }
        xml = model.replacingTexts(texts)
        model = TableModel(xml: xml) ?? model
    }

    private func change(_ edit: (TableModel) -> Data) {
        commitTexts()
        let new = edit(model)
        guard let m = TableModel(xml: new) else { return NSSound.beep() }
        xml = new
        model = m
        rebuildGrid()
    }

    private var focusedColumn: Int {
        model.rows[safe: focused.row]?.cells[safe: focused.cell]?.gridStart ?? 0
    }

    @objc func addRow(_ sender: Any?) {
        let row = focused.row
        change { $0.addingRow(after: row) }
        focused = TableModel.CellPosition(row: row + 1, cell: 0)
        rebuildGrid()
    }

    @objc private func removeRow(_ sender: Any?) {
        let row = focused.row
        change { $0.removingRow(row) }
    }

    @objc private func addColumn(_ sender: Any?) {
        let column = focusedColumn
        change { $0.addingColumn(after: column) }
    }

    @objc private func removeColumn(_ sender: Any?) {
        let column = focusedColumn
        change { $0.removingColumn(column) }
    }

    @objc private func cancel(_ sender: Any?) { end() }

    @objc func done(_ sender: Any?) {
        commitTexts()
        let result = xml
        let changed = result != original
        end()
        if changed { onDone?(result) }
    }

    private func end() {
        guard let window, let parent = window.sheetParent else {
            window?.close()
            return
        }
        parent.endSheet(window)
    }
}

/// A flipped container so the grid starts at the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
