import AppKit
import LibretillaDocx
import SwiftUI

/// The cell editor sheet (ADR 0006): a table's cells as a grid of text fields, plus rows and columns.
/// Works on the table's XML; `onDone` gets the edited XML (only if something changed).
@MainActor @Observable
final class TableEditorSheet {
    typealias Position = TableModel.CellPosition

    private(set) var model: TableModel
    /// The text of each cell that can be edited, as typed.
    var texts: [Position: String] = [:]
    /// The cell last typed in: rows and columns are added after it and removed at it.
    var focused: Position
    @ObservationIgnored private let original: Data
    @ObservationIgnored var onDone: ((Data) -> Void)?
    @ObservationIgnored private(set) var window: NSWindow?

    init?(xml: Data, row: Int) {
        guard let model = TableModel(xml: xml) else { return nil }
        original = xml
        self.model = model
        focused = Position(row: min(max(0, row), model.rows.count - 1), cell: 0)
        loadTexts()
    }

    /// Shows the sheet on `parent`; `onEnd` runs once it has gone.
    func present(on parent: NSWindow, onEnd: @escaping @MainActor () -> Void) {
        let window = Sheet.window(
            String(localized: "Edit Table"), resizable: true, content: TableEditorView(sheet: self))
        window.setContentSize(NSSize(width: 640, height: 420))
        window.contentMinSize = NSSize(width: 420, height: 240)
        self.window = window
        parent.beginSheet(window) { _ in MainActor.assumeIsolated { onEnd() } }
    }

    private func loadTexts() {
        texts = [:]
        for (r, row) in model.rows.enumerated() {
            for (c, cell) in row.cells.enumerated() where cell.isEditable && cell.verticalMerge != .continue {
                texts[Position(row: r, cell: c)] = cell.text
            }
        }
    }

    /// The table with the text currently in the fields.
    var xml: Data { model.replacingTexts(texts) }

    private func change(_ edit: (TableModel) -> Data) {
        let current = TableModel(xml: xml) ?? model
        guard let new = TableModel(xml: edit(current)) else { return NSSound.beep() }
        model = new
        loadTexts()
        focused.row = min(focused.row, model.rows.count - 1)
        if model.rows[focused.row].cells.indices.contains(focused.cell) == false { focused.cell = 0 }
    }

    private var focusedColumn: Int { model.rows[safe: focused.row]?.cells[safe: focused.cell]?.gridStart ?? 0 }

    func addRow() {
        let row = focused.row
        change { $0.addingRow(after: row) }
        focused = Position(row: row + 1, cell: 0)
    }

    func removeRow() {
        let row = focused.row
        change { $0.removingRow(row) }
    }

    func addColumn() {
        let column = focusedColumn
        change { $0.addingColumn(after: column) }
    }

    func removeColumn() {
        let column = focusedColumn
        change { $0.removingColumn(column) }
    }

    func cancel() { Sheet.end(window) }

    func done() {
        window?.makeFirstResponder(nil)
        let result = xml
        Sheet.end(window)
        if result != original { onDone?(result) }
    }
}

private struct TableEditorView: View {
    @Bindable var sheet: TableEditorSheet
    @FocusState private var focus: TableEditorSheet.Position?

    /// What sits in each grid column of a row: a cell (with its span) or nothing.
    private struct Slot: Identifiable {
        var id: Int  // The grid column it starts at.
        var cell: Int?
        var span = 1
    }

    private var columnCount: Int { max(1, sheet.model.columns.count) }

    private func slots(_ row: TableModel.Row) -> [Slot] {
        var slots: [Slot] = []
        var column = 0
        for (c, cell) in row.cells.enumerated() where cell.gridStart < columnCount && cell.gridStart >= column {
            slots += (column..<cell.gridStart).map { Slot(id: $0) }
            let span = cell.gridStart + cell.span <= columnCount ? max(1, cell.span) : 1
            slots.append(Slot(id: cell.gridStart, cell: c, span: span))
            column = cell.gridStart + span
        }
        return slots + (column..<columnCount).map { Slot(id: $0) }
    }

    /// Column widths in proportion to the table's, at least 90 points each.
    private func width(_ slot: Slot) -> CGFloat {
        let total = max(1, sheet.model.columns.reduce(0, +))
        let widths = (slot.id..<slot.id + slot.span).map { c in
            let share = c < sheet.model.columns.count ? sheet.model.columns[c] / total : 1 / Double(columnCount)
            return max(90, CGFloat(share) * 540)
        }
        return widths.reduce(0, +) + CGFloat(slot.span - 1) * 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .topLeading, horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(Array(sheet.model.rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(slots(row)) { slot in
                                if let c = slot.cell {
                                    field(
                                        TableEditorSheet.Position(row: r, cell: c), row.cells[c], header: row.isHeader
                                    )
                                    .frame(width: width(slot))
                                    .gridCellColumns(slot.span)
                                } else {
                                    Color.clear.frame(width: width(slot), height: 1)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
            Text(String(localized: "Press Option-Return for a new line in a cell."))
                .font(.callout)
                .foregroundStyle(.secondary)
            SheetButtons(cancel: sheet.cancel, confirmTitle: String(localized: "Done"), confirm: sheet.done) {
                Button(String(localized: "Add Row"), action: sheet.addRow)
                Button(String(localized: "Remove Row"), action: sheet.removeRow)
                    .disabled(sheet.model.rows.count <= 1)
                Group {
                    Button(String(localized: "Add Column"), action: sheet.addColumn)
                    Button(String(localized: "Remove Column"), action: sheet.removeColumn)
                }
                .disabled(!sheet.model.isSimpleGrid)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240)
        .onAppear { focus = sheet.focused }
        .onChange(of: focus) { if let focus { sheet.focused = focus } }
        .onChange(of: sheet.focused) { focus = sheet.focused }
    }

    /// A cell's field: merged-away cells are shown empty and disabled, cells the editor can't change disabled.
    private func field(_ pos: TableEditorSheet.Position, _ cell: TableModel.Cell, header: Bool) -> some View {
        let merged = cell.verticalMerge == .continue
        let text = Binding(
            get: { sheet.texts[pos] ?? (merged ? "" : cell.text) }, set: { sheet.texts[pos] = $0 })
        return TextField(merged ? String(localized: "(merged)") : "", text: text, axis: .vertical)
            .labelsHidden()
            .fontWeight(header ? .bold : nil)
            .disabled(merged || !cell.isEditable)
            .help(
                !merged && !cell.isEditable ? String(localized: "This cell has content the editor can't change.") : ""
            )
            .focused($focus, equals: pos)
    }
}
