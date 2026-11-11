import Foundation

// Tables (ADR 0006). A `w:tbl` stays an opaque block, written back byte for byte unless edited; `TableModel`
// reads it for drawing and for the cell editor, and edits splice only the cells or rows they change.

/// One border line (`w:top`, `w:insideH`, … in `w:tblBorders` / `w:tcBorders`).
public struct TableBorder: Sendable, Equatable {
    /// `single`, `double`, `dashed`, … ; `nil` and `none` mean no line.
    public var style: String
    /// Line width in points (`w:sz` is in eighths of a point).
    public var width: Double
    /// Hex `RRGGBB`, or nil for automatic.
    public var color: String?

    public var isVisible: Bool { style != "nil" && style != "none" }

    init?(_ e: RawXML.Element?) {
        guard let e, let style = e.attribute("w:val") else { return nil }
        self.style = style
        width = (e.attribute("w:sz").flatMap(Double.init) ?? 4) / 8
        let c = e.attribute("w:color")
        color = c == nil || c == "auto" ? nil : c
    }
}

public struct TableBorders: Sendable, Equatable {
    public var top, left, bottom, right, insideH, insideV: TableBorder?

    public init() {}

    init(_ e: RawXML.Element?) {
        guard let e else { return }
        top = TableBorder(e.firstChild(named: "w:top"))
        left = TableBorder(e.firstChild(named: "w:left") ?? e.firstChild(named: "w:start"))
        bottom = TableBorder(e.firstChild(named: "w:bottom"))
        right = TableBorder(e.firstChild(named: "w:right") ?? e.firstChild(named: "w:end"))
        insideH = TableBorder(e.firstChild(named: "w:insideH"))
        insideV = TableBorder(e.firstChild(named: "w:insideV"))
    }

    /// These borders where set, `base` elsewhere.
    func over(_ base: TableBorders) -> TableBorders {
        var out = base
        if let top { out.top = top }
        if let left { out.left = left }
        if let bottom { out.bottom = bottom }
        if let right { out.right = right }
        if let insideH { out.insideH = insideH }
        if let insideV { out.insideV = insideV }
        return out
    }
}

/// What a table style's conditional formatting (`w:tblStylePr`, or the style's own `w:tcPr` and `w:rPr` for the
/// whole table) gives the cells it applies to: shading, borders, and bold, italic and colour for their text.
public struct TableConditionalFormat: Sendable, Equatable {
    /// Hex `RRGGBB`.
    public var fill: String?
    public var borders = TableBorders()
    public var bold, italic: Bool?
    /// Hex `RRGGBB`.
    public var color: String?

    public init() {}

    /// From an element holding a `w:tcPr` and a `w:rPr` (a `w:tblStylePr` or a table `w:style`).
    init(_ e: RawXML.Element) {
        let tcPr = e.firstChild(named: "w:tcPr")
        fill = tcPr?.firstChild(named: "w:shd")?.attribute("w:fill").flatMap { $0 == "auto" ? nil : $0 }
        borders = TableBorders(tcPr?.firstChild(named: "w:tcBorders"))
        let rPr = e.firstChild(named: "w:rPr")
        bold = rPr?.firstChild(named: "w:b").map(RunProperties.toggle)
        italic = rPr?.firstChild(named: "w:i").map(RunProperties.toggle)
        color = rPr?.firstChild(named: "w:color")?.attribute("w:val").flatMap { $0 == "auto" ? nil : $0 }
    }

    /// These values where set, `base` elsewhere.
    func over(_ base: TableConditionalFormat) -> TableConditionalFormat {
        var out = base
        out.fill = fill ?? base.fill
        out.borders = borders.over(base.borders)
        out.bold = bold ?? base.bold
        out.italic = italic ?? base.italic
        out.color = color ?? base.color
        return out
    }
}

/// `w:tblLook`: which of its style's conditional formats a table uses. Without one, a table uses only the banding.
public struct TableLook: Sendable, Equatable {
    public var firstRow = false, lastRow = false, firstColumn = false, lastColumn = false
    public var rowBands = true, columnBands = true

    public init() {}

    init(_ e: RawXML.Element) {
        // Word 2010 and later write attributes; Word 2007 only a bit mask in w:val.
        let mask = e.attribute("w:val").flatMap { Int($0, radix: 16) } ?? 0
        func flag(_ name: String, _ bit: Int) -> Bool {
            e.attribute(name).map { $0 == "1" || $0 == "true" || $0 == "on" } ?? (mask & bit != 0)
        }
        firstRow = flag("w:firstRow", 0x0020)
        lastRow = flag("w:lastRow", 0x0040)
        firstColumn = flag("w:firstColumn", 0x0080)
        lastColumn = flag("w:lastColumn", 0x0100)
        rowBands = !flag("w:noHBand", 0x0200)
        columnBands = !flag("w:noVBand", 0x0400)
    }
}

/// What a `w:tblPr` (in a table or a table style) says about borders, cell margins and placement.
public struct TableProperties: Sendable, Equatable {
    public var styleId: String?
    public var borders = TableBorders()
    /// Cell margins in points (`w:tblCellMar`).
    public var cellMarginLeft, cellMarginRight, cellMarginTop, cellMarginBottom: Double?
    /// `left`, `center`, `right` (`w:jc`).
    public var alignment: String?
    /// Indent from the margin in points (`w:tblInd`).
    public var indent: Double?
    /// The table's `w:tblLook`.
    public var look: TableLook?
    /// How many rows and columns each band covers (`w:tblStyleRowBandSize`, `w:tblStyleColBandSize`).
    public var rowBandSize, columnBandSize: Int?
    /// A table style's conditional formats, by `w:type` (`firstRow`, `band1Horz`, …, and `wholeTable`).
    public var conditional: [String: TableConditionalFormat] = [:]

    public init() {}

    init(_ tblPr: RawXML.Element?) {
        guard let tblPr else { return }
        func pt(_ e: RawXML.Element?) -> Double? {
            guard let e, (e.attribute("w:type") ?? "dxa") == "dxa" else { return nil }
            return e.attribute("w:w").flatMap(Double.init).map { $0 / 20 }
        }
        styleId = tblPr.firstChild(named: "w:tblStyle")?.attribute("w:val")
        borders = TableBorders(tblPr.firstChild(named: "w:tblBorders"))
        if let mar = tblPr.firstChild(named: "w:tblCellMar") {
            cellMarginLeft = pt(mar.firstChild(named: "w:left") ?? mar.firstChild(named: "w:start"))
            cellMarginRight = pt(mar.firstChild(named: "w:right") ?? mar.firstChild(named: "w:end"))
            cellMarginTop = pt(mar.firstChild(named: "w:top"))
            cellMarginBottom = pt(mar.firstChild(named: "w:bottom"))
        }
        alignment = tblPr.firstChild(named: "w:jc")?.attribute("w:val")
        indent = pt(tblPr.firstChild(named: "w:tblInd"))
        look = tblPr.firstChild(named: "w:tblLook").map(TableLook.init)
        rowBandSize = tblPr.firstChild(named: "w:tblStyleRowBandSize")?.attribute("w:val").flatMap { Int($0) }
        columnBandSize = tblPr.firstChild(named: "w:tblStyleColBandSize")?.attribute("w:val").flatMap { Int($0) }
    }

    /// These properties where set, `base` elsewhere.
    func over(_ base: TableProperties) -> TableProperties {
        var out = base
        out.styleId = styleId ?? base.styleId
        out.borders = borders.over(base.borders)
        out.cellMarginLeft = cellMarginLeft ?? base.cellMarginLeft
        out.cellMarginRight = cellMarginRight ?? base.cellMarginRight
        out.cellMarginTop = cellMarginTop ?? base.cellMarginTop
        out.cellMarginBottom = cellMarginBottom ?? base.cellMarginBottom
        out.alignment = alignment ?? base.alignment
        out.indent = indent ?? base.indent
        out.look = look ?? base.look
        out.rowBandSize = rowBandSize ?? base.rowBandSize
        out.columnBandSize = columnBandSize ?? base.columnBandSize
        out.conditional = base.conditional.merging(conditional) { $1.over($0) }
        return out
    }

    /// The conditional formats `look` turns on for the cell in row `row` of `rows`, spanning grid columns
    /// `columns` of `columnCount`, combined in Word's order: the whole table, column bands, row bands, the first
    /// and last columns, the first and last rows, then the corner cells.
    public func conditionalFormat(row: Int, of rows: Int, columns: Range<Int>, of columnCount: Int)
        -> TableConditionalFormat
    {
        let look = look ?? TableLook()
        let isFirstRow = look.firstRow && row == 0
        let isLastRow = look.lastRow && row == rows - 1
        let isFirstColumn = look.firstColumn && columns.lowerBound == 0
        let isLastColumn = look.lastColumn && columns.upperBound == columnCount
        var types = ["wholeTable"]
        if look.columnBands, !isFirstColumn, !isLastColumn {
            let band = (columns.lowerBound - (look.firstColumn ? 1 : 0)) / max(1, columnBandSize ?? 1)
            types.append(band % 2 == 0 ? "band1Vert" : "band2Vert")
        }
        if look.rowBands, !isFirstRow, !isLastRow {
            let band = (row - (look.firstRow ? 1 : 0)) / max(1, rowBandSize ?? 1)
            types.append(band % 2 == 0 ? "band1Horz" : "band2Horz")
        }
        if isFirstColumn { types.append("firstCol") }
        if isLastColumn { types.append("lastCol") }
        if isFirstRow { types.append("firstRow") }
        if isLastRow { types.append("lastRow") }
        if isFirstRow && isFirstColumn { types.append("nwCell") }
        if isFirstRow && isLastColumn { types.append("neCell") }
        if isLastRow && isFirstColumn { types.append("swCell") }
        if isLastRow && isLastColumn { types.append("seCell") }
        return types.reduce(TableConditionalFormat()) { out, type in conditional[type]?.over(out) ?? out }
    }
}

public struct TableModel: Sendable {
    public enum VerticalMerge: Sendable, Equatable { case none, restart, `continue` }

    public enum Content: Sendable {
        case paragraph(Paragraph)
        case text(String)
    }

    public struct Cell: Sendable {
        /// First grid column the cell covers, and how many it spans.
        public var gridStart: Int
        public var span: Int
        public var verticalMerge: VerticalMerge
        /// Shading fill, hex `RRGGBB`.
        public var fill: String?
        public var borders: TableBorders
        public var paragraphs: [Paragraph]
        /// Text of content the cell holds besides paragraphs (nested tables, content controls), one line each.
        public var otherText: [String]
        /// Everything in the cell, in order: paragraphs, and lines of text for other content.
        public var contents: [Content]
        /// Only plain paragraphs of plain runs: the cell editor can change its text.
        public var isEditable: Bool
        /// The cell's text, one line per paragraph (what the cell editor shows).
        public var text: String { (paragraphs.map(\.text) + otherText).joined(separator: "\n") }
        /// Byte ranges in the table XML: the whole `w:tc`, and its content (after its `w:tcPr`).
        let range: Range<Int>
        let contentRange: Range<Int>
        let tcPrRange: Range<Int>?
        let firstParagraph: Paragraph?
    }

    public struct Row: Sendable {
        public var cells: [Cell]
        /// Repeats at the top of each page (`w:tblHeader`).
        public var isHeader: Bool
        /// `w:trHeight` in points, and whether it's exact (else at least).
        public var height: Double?
        public var heightIsExact: Bool
        let range: Range<Int>
    }

    public let xml: Data
    /// Grid column widths in points.
    public var columns: [Double]
    public var rows: [Row]
    /// The table's own `w:tblPr`.
    public var properties: TableProperties

    /// Every row has one cell per column: rows and columns can be added and removed freely.
    public var isSimpleGrid: Bool {
        rows.allSatisfy { row in
            row.cells.count == columns.count && row.cells.allSatisfy { $0.span == 1 && $0.verticalMerge == .none }
        }
    }

    /// Nil if the table has structure Libretilla doesn't read (rows or cells inside content controls, …).
    public init?(xml: Data) {
        let bytes = Data([UInt8](xml))
        guard let doc = try? RawXML.Document(data: bytes, part: "w:tbl"), doc.root.name == "w:tbl" else { return nil }
        self.xml = bytes
        let tbl = doc.root
        properties = TableProperties(tbl.firstChild(named: "w:tblPr"))
        columns =
            tbl.firstChild(named: "w:tblGrid")?.childElements(named: "w:gridCol").map {
                ($0.attribute("w:w").flatMap(Double.init) ?? 0) / 20
            } ?? []
        var rows: [Row] = []
        for child in tbl.childElements {
            switch child.name {
            case "w:tblPr", "w:tblGrid", "w:bookmarkStart", "w:bookmarkEnd", "w:proofErr": continue
            case "w:tr":
                guard let row = Self.row(child, in: doc) else { return nil }
                rows.append(row)
            default: return nil
            }
        }
        guard !rows.isEmpty else { return nil }
        self.rows = rows
        // Tables without a usable grid: equal columns over the widest row.
        if columns.isEmpty || columns.allSatisfy({ $0 <= 0 }) {
            let n = rows.map { $0.cells.reduce(0) { $0 + $1.span } }.max() ?? 1
            columns = Array(repeating: 468 / Double(n), count: n)
        }
    }

    private static func row(_ tr: RawXML.Element, in doc: RawXML.Document) -> Row? {
        let trPr = tr.firstChild(named: "w:trPr")
        var column = trPr?.firstChild(named: "w:gridBefore")?.attribute("w:val").flatMap { Int($0) } ?? 0
        var cells: [Cell] = []
        for child in tr.childElements {
            switch child.name {
            case "w:trPr", "w:tblPrEx", "w:bookmarkStart", "w:bookmarkEnd", "w:proofErr": continue
            case "w:tc":
                let cell = Self.cell(child, gridStart: column, in: doc)
                column += cell.span
                cells.append(cell)
            default: return nil
            }
        }
        let height = trPr?.firstChild(named: "w:trHeight")
        return Row(
            cells: cells, isHeader: trPr?.firstChild(named: "w:tblHeader").map { RunProperties.toggle($0) } ?? false,
            height: height?.attribute("w:val").flatMap(Double.init).map { $0 / 20 },
            heightIsExact: height?.attribute("w:hRule") == "exact", range: tr.range)
    }

    private static func cell(_ tc: RawXML.Element, gridStart: Int, in doc: RawXML.Document) -> Cell {
        let tcPr = tc.firstChild(named: "w:tcPr")
        let merge: VerticalMerge =
            switch tcPr?.firstChild(named: "w:vMerge") {
            case nil: .none
            case let e?: e.attribute("w:val") == "restart" ? .restart : .continue
            }
        let fill = tcPr?.firstChild(named: "w:shd")?.attribute("w:fill")
        var paragraphs: [Paragraph] = []
        var other: [String] = []
        var contents: [Content] = []
        var editable = true
        for child in tc.childElements where child.name != "w:tcPr" {
            switch child.name {
            case "w:p":
                let p = Paragraph(parsing: child, in: doc, leadingTrivia: Data())
                if !p.inlines.allSatisfy({ if case .run = $0 { true } else { false } }) { editable = false }
                paragraphs.append(p)
                contents.append(.paragraph(p))
            case "w:tbl":
                editable = false
                for tr in child.childElements(named: "w:tr") {
                    contents.append(
                        .text(
                            tr.childElements(named: "w:tc").map { tc in
                                tc.descendants(named: "w:p").map { p in
                                    p.childElements.map { OpaqueInline.visibleText($0) }.joined()
                                }.joined(separator: " ")
                            }.joined(separator: " · ")))
                    if case .text(let t) = contents.last { other.append(t) }
                }
            default:
                editable = false
                for p in child.descendants(named: "w:p") {
                    let t = p.childElements.map { OpaqueInline.visibleText($0) }.joined()
                    other.append(t)
                    contents.append(.text(t))
                }
            }
        }
        let start = tcPr?.range.upperBound ?? tc.startTagRange.upperBound
        return Cell(
            gridStart: gridStart,
            span: max(1, tcPr?.firstChild(named: "w:gridSpan")?.attribute("w:val").flatMap { Int($0) } ?? 1),
            verticalMerge: merge, fill: fill == "auto" ? nil : fill,
            borders: TableBorders(tcPr?.firstChild(named: "w:tcBorders")), paragraphs: paragraphs, otherText: other,
            contents: contents,
            isEditable: editable, range: tc.range, contentRange: start..<tc.endTagRange.lowerBound,
            tcPrRange: tcPr?.range,
            firstParagraph: paragraphs.first)
    }

    // MARK: - Editing

    public struct CellPosition: Hashable, Sendable {
        public var row: Int
        public var cell: Int
        public init(row: Int, cell: Int) {
            self.row = row
            self.cell = cell
        }
    }

    /// The table with new text in some cells (one paragraph per line). Only editable cells whose text
    /// changed are rewritten; each new paragraph keeps the formatting of the cell's first paragraph and run.
    public func replacingTexts(_ texts: [CellPosition: String]) -> Data {
        var edits: [(Range<Int>, Data)] = []
        for (pos, text) in texts {
            guard rows.indices.contains(pos.row), rows[pos.row].cells.indices.contains(pos.cell) else { continue }
            let cell = rows[pos.row].cells[pos.cell]
            guard cell.isEditable, cell.text != text else { continue }
            edits.append((cell.contentRange, Self.paragraphs(text, like: cell.firstParagraph)))
        }
        return Self.splicing(xml, edits)
    }

    /// Cell content: one paragraph per line, formatted like `template` (its `w:pPr` and first run's `w:rPr`).
    static func paragraphs(_ text: String, like template: Paragraph?) -> Data {
        let pPr = template?.propertiesXMLWithoutSectionBreak ?? template?.propertiesXML
        var run: Run?
        for case .run(let r) in template?.inlines ?? [] {
            run = r
            break
        }
        var out = Data()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var p = Paragraph(properties: template?.properties ?? ParagraphProperties(), propertiesXML: pPr)
            if !line.isEmpty {
                p.inlines = [
                    .run(
                        Run(
                            text: String(line), properties: run?.properties ?? RunProperties(),
                            propertiesXML: run?.propertiesXML))
                ]
            }
            out.append(p.serialized())
        }
        return out
    }

    /// The table with an empty row added after row `index` (a copy of that row's cells, without text,
    /// vertical merges or header flag).
    public func addingRow(after index: Int) -> Data {
        guard rows.indices.contains(index) else { return xml }
        let row = rows[index]
        var copy = [UInt8](xml[row.range])
        // Edit the copy from its last cell back, so earlier offsets stay valid.
        let base = row.range.lowerBound
        for cell in row.cells.reversed() {
            let content = (cell.contentRange.lowerBound - base)..<(cell.contentRange.upperBound - base)
            copy.replaceSubrange(content, with: [UInt8](Self.paragraphs("", like: cell.firstParagraph)))
            if let r = cell.tcPrRange {
                let tcPr = Data(xml[r])
                let cleaned =
                    ElementPatch.apply(
                        [.remove("w:vMerge")], to: tcPr, wrapper: "w:tcPr", order: Self.cellPropertiesOrder)
                    ?? Data()
                copy.replaceSubrange((r.lowerBound - base)..<(r.upperBound - base), with: [UInt8](cleaned))
            }
        }
        var rowXML = Data(copy)
        if let doc = try? RawXML.Document(data: rowXML, part: "w:tr"), let trPr = doc.root.firstChild(named: "w:trPr") {
            let cleaned =
                ElementPatch.apply([.remove("w:tblHeader")], to: Data(rowXML[trPr.range]), wrapper: "w:trPr", order: [])
                ?? Data()
            rowXML.replaceSubrange(trPr.range, with: cleaned)
        }
        return Self.splicing(xml, [(row.range.upperBound..<row.range.upperBound, rowXML)])
    }

    /// The table without row `index` (the last row can't be removed). A vertical merge that started in the
    /// removed row restarts in the next one.
    public func removingRow(_ index: Int) -> Data {
        guard rows.count > 1, rows.indices.contains(index) else { return xml }
        var edits: [(Range<Int>, Data)] = [(rows[index].range, Data())]
        if index + 1 < rows.count {
            for cell in rows[index].cells where cell.verticalMerge == .restart {
                guard
                    let below = rows[index + 1].cells.first(where: {
                        $0.gridStart == cell.gridStart && $0.verticalMerge == .continue
                    }), let r = below.tcPrRange
                else { continue }
                let patched =
                    ElementPatch.apply(
                        [.replace("w:vMerge", xml: "<w:vMerge w:val=\"restart\"/>")], to: Data(xml[r]),
                        wrapper: "w:tcPr",
                        order: Self.cellPropertiesOrder) ?? Data()
                edits.append((r, patched))
            }
        }
        return Self.splicing(xml, edits)
    }

    /// The table with an empty column added after column `index` (simple grids only). Columns are made
    /// equal, keeping the table's width.
    public func addingColumn(after index: Int) -> Data {
        guard isSimpleGrid, columns.indices.contains(index) else { return xml }
        let total = columns.reduce(0, +)
        let width = Int((total / Double(columns.count + 1) * 20).rounded())
        var edits: [(Range<Int>, Data)] = []
        for row in rows {
            for (i, cell) in row.cells.enumerated() {
                if let r = cell.tcPrRange { edits.append((r, Self.withWidth(Data(xml[r]), width))) }
                if i == index {
                    let end = cell.range.upperBound
                    let newCell =
                        "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                        + String(decoding: Self.paragraphs("", like: cell.firstParagraph), as: UTF8.self) + "</w:tc>"
                    edits.append((end..<end, Data(newCell.utf8)))
                }
            }
        }
        edits.append(gridEdit(Array(repeating: width, count: columns.count + 1)))
        return Self.splicing(xml, edits)
    }

    /// The table without column `index` (simple grids only; the last column can't be removed).
    public func removingColumn(_ index: Int) -> Data {
        guard isSimpleGrid, columns.count > 1, columns.indices.contains(index) else { return xml }
        var edits: [(Range<Int>, Data)] = []
        for row in rows { edits.append((row.cells[index].range, Data())) }
        var widths = columns.map { Int(($0 * 20).rounded()) }
        widths.remove(at: index)
        edits.append(gridEdit(widths))
        return Self.splicing(xml, edits)
    }

    private func gridEdit(_ widths: [Int]) -> (Range<Int>, Data) {
        let grid = "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        guard let doc = try? RawXML.Document(data: xml, part: "w:tbl"),
            let existing = doc.root.firstChild(named: "w:tblGrid")
        else {
            let at =
                (try? RawXML.Document(data: xml, part: "w:tbl"))?.root.firstChild(named: "w:tblPr")?.range.upperBound
                ?? 0
            return (at..<at, Data(grid.utf8))
        }
        return (existing.range, Data(grid.utf8))
    }

    private static func withWidth(_ tcPr: Data, _ width: Int) -> Data {
        ElementPatch.apply(
            [.attributes("w:tcW", [("w:w", String(width)), ("w:type", "dxa")])], to: tcPr, wrapper: "w:tcPr",
            order: cellPropertiesOrder) ?? tcPr
    }

    /// Applies non-overlapping byte replacements, last first.
    static func splicing(_ xml: Data, _ edits: [(Range<Int>, Data)]) -> Data {
        var out = [UInt8](xml)
        for (range, data) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: [UInt8](data))
        }
        return Data(out)
    }

    /// Children of `w:tcPr` (CT_TcPr) in schema order.
    static let cellPropertiesOrder = [
        "w:cnfStyle", "w:tcW", "w:gridSpan", "w:hMerge", "w:vMerge", "w:tcBorders", "w:shd", "w:noWrap", "w:tcMar",
        "w:textDirection", "w:tcFitText", "w:vAlign", "w:hideMark", "w:headers", "w:cellIns", "w:cellDel",
        "w:cellMerge", "w:tcPrChange",
    ]

    // MARK: - New tables

    /// A new empty table, `columns` equal columns across `width` points, in the "Table Grid" style if the
    /// document has it (`styleId`), else with single borders of its own.
    public static func newTable(rows: Int, columns: Int, width: Double, styleId: String?) -> Data {
        let col = Int((width / Double(columns) * 20).rounded())
        var tblPr = "<w:tblPr>"
        if let styleId { tblPr += "<w:tblStyle w:val=\"\(RawXML.escapeAttribute(styleId))\"/>" }
        tblPr += "<w:tblW w:w=\"0\" w:type=\"auto\"/>"
        if styleId == nil {
            let line = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\""
            tblPr +=
                "<w:tblBorders>"
                + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(line)/>" }
                .joined() + "</w:tblBorders>"
        }
        tblPr +=
            "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"1\" w:lastColumn=\"0\""
            + " w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr>"
        let grid = "<w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(col)\"/>", count: columns) + "</w:tblGrid>"
        let cell = "<w:tc><w:tcPr><w:tcW w:w=\"\(col)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
        let row = "<w:tr>" + String(repeating: cell, count: columns) + "</w:tr>"
        return Data(("<w:tbl>" + tblPr + grid + String(repeating: row, count: rows) + "</w:tbl>").utf8)
    }
}

extension OpaqueBlock {
    /// A body-level block from its XML (a new or edited table), or nil if it isn't well formed.
    public init?(xml: Data, leadingTrivia: Data = Data()) {
        guard let doc = try? RawXML.Document(data: Data([UInt8](xml)), part: "block") else { return nil }
        self.init(parsing: doc.root, in: doc, leadingTrivia: leadingTrivia)
    }
}

extension StyleSheet {
    /// The table properties a table style gives, through its `basedOn` chain.
    public func tableProperties(_ styleId: String?) -> TableProperties {
        var out = TableProperties()
        for style in chain(styleId) where style.type == "table" {
            guard let xml = styleElement(style.id), let doc = try? RawXML.Document(data: xml, part: "w:style") else {
                continue
            }
            var own = TableProperties(doc.root.firstChild(named: "w:tblPr"))
            // A style's own cell shading and run formatting apply to the whole table.
            own.conditional["wholeTable"] = TableConditionalFormat(doc.root)
            for e in doc.root.childElements(named: "w:tblStylePr") {
                guard let type = e.attribute("w:type") else { continue }
                own.conditional[type] = TableConditionalFormat(e)
            }
            out = own.over(out)
        }
        return out
    }

    /// The paragraph spacing a table style gives the paragraphs in its cells (Word applies it below the
    /// paragraph style): space after and line spacing, through its `basedOn` chain.
    public func tableParagraphProperties(_ styleId: String?) -> ParagraphProperties {
        var out = ParagraphProperties()
        for style in chain(styleId) where style.type == "table" {
            let p = style.paragraph
            if let v = p.spaceAfter { out.spaceAfter = v }
            if let v = p.spaceBefore { out.spaceBefore = v }
            if let v = p.line {
                out.line = v
                out.lineRule = p.lineRule
            }
        }
        return out
    }

    /// The paragraph style chain (not document defaults) of `id` sets space after / line spacing.
    func paragraphStyleSetsSpacing(_ id: String?) -> (after: Bool, line: Bool) {
        let c = chain(id ?? defaultParagraphStyleId)
        return (c.contains { $0.paragraph.spaceAfter != nil }, c.contains { $0.paragraph.line != nil })
    }
}
