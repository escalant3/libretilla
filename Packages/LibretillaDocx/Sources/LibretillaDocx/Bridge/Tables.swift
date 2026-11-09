import AppKit

// Tables (ADR 0006): each row of a `w:tbl` shows as one attachment line, drawn from the model. All rows (and
// the line breaks between them) carry the table's `OpaqueBlockBox`, so the table is edited whole or not at
// all, and saved from its XML once.

extension NSAttributedString.Key {
    /// The row index on each table row's attachment character.
    public static let libretillaTableRow = NSAttributedString.Key("libretilla.tableRow")
}

/// Cell geometry and text for drawing a table, in points.
struct TableLayout {
    struct Cell {
        var frame: CGRect  // within its row; height is the row's
        var text: NSAttributedString?
        var fill: NSColor?
        var top, left, bottom, right: TableBorder?
        var textInsets: NSEdgeInsets
    }

    struct Row {
        var height: CGFloat
        var cells: [Cell]
    }

    var width: CGFloat
    var rows: [Row]
    var alignment: NSTextAlignment
    var indent: CGFloat
}

extension AttributedStringBridge {
    /// One attachment line per row, or nil if the table can't be read (it then shows as a placeholder).
    public func tableText(_ o: OpaqueBlock, leadingBlocks: [OpaqueBlock]) -> NSAttributedString? {
        guard o.kind == "w:tbl", let model = TableModel(xml: o.xml) else { return nil }
        let layout = tableLayout(model)
        let box = OpaqueBlockBox(o, leadingBlocks: leadingBlocks)
        // A tiny font so each line is exactly as tall as its row.
        let font = NSFont.systemFont(ofSize: 1)
        let style = NSMutableParagraphStyle()
        style.alignment = layout.alignment
        style.firstLineHeadIndent = layout.indent
        style.headIndent = layout.indent
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        let out = NSMutableAttributedString()
        for (i, row) in layout.rows.enumerated() {
            let attachment = NSTextAttachment()
            attachment.image = Self.rowImage(row, width: layout.width)
            attachment.bounds = NSRect(x: 0, y: font.descender, width: layout.width, height: row.height)
            let attrs: [NSAttributedString.Key: Any] = [
                .attachment: attachment, .libretillaBlock: box, .libretillaTableRow: i, .font: font,
                .paragraphStyle: style,
            ]
            out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            var newline = attrs
            newline[.attachment] = nil
            newline[.libretillaTableRow] = nil
            // The last line break isn't part of the table: text typed after it starts a normal paragraph.
            if i == layout.rows.count - 1 {
                newline[.libretillaBlock] = nil
                let (_, run) = styles.resolveParagraphStyle(nil)
                newline[.font] = characterAttributes(run)[.font]
            }
            out.append(NSAttributedString(string: "\n", attributes: newline))
        }
        return out
    }

    func tableLayout(_ model: TableModel) -> TableLayout {
        let props = model.properties.over(styles.tableProperties(model.properties.styleId))
        let tableParagraph = styles.tableParagraphProperties(props.styleId)
        // Word's default cell margins (Normal Table): 0.08″ left and right, none above and below.
        let marginLeft = CGFloat(props.cellMarginLeft ?? 5.4)
        let marginRight = CGFloat(props.cellMarginRight ?? 5.4)
        let marginTop = CGFloat(props.cellMarginTop ?? 0)
        let marginBottom = CGFloat(props.cellMarginBottom ?? 0)

        // Wider than the text column: scale the columns down to fit (the text wraps narrower).
        let natural = model.columns.reduce(0, +)
        let scale = natural > Double(textWidth) && natural > 0 ? Double(textWidth) / natural : 1
        let columns = model.columns.map { CGFloat($0 * scale) }
        var edges = [CGFloat(0)]
        for c in columns { edges.append(edges.last! + c) }
        let width = edges.last!

        var rows: [TableLayout.Row] = []
        for (r, row) in model.rows.enumerated() {
            var cells: [TableLayout.Cell] = []
            var height: CGFloat = 0
            for cell in row.cells {
                let start = min(cell.gridStart, columns.count)
                let end = min(cell.gridStart + cell.span, columns.count)
                guard end > start else { continue }
                let x = edges[start]
                let w = edges[end] - x
                let isFirstRow = r == 0
                let isLastRow = r == model.rows.count - 1
                let continues = cell.verticalMerge == .continue
                // Is the cell below a continuation of this one?
                let mergesDown =
                    !isLastRow
                    && model.rows[r + 1].cells.contains {
                        $0.gridStart == cell.gridStart && $0.verticalMerge == .continue
                    }
                var top = isFirstRow ? props.borders.top : props.borders.insideH
                if continues { top = nil }
                var bottom = isLastRow ? props.borders.bottom : nil  // the next row draws its top
                if mergesDown { bottom = nil }
                var left = start == 0 ? props.borders.left : props.borders.insideV
                var right = end == columns.count ? props.borders.right : nil  // the next cell draws its left
                if let b = cell.borders.top, !continues { top = b }
                if let b = cell.borders.left { left = b }
                if let b = cell.borders.right { right = b }
                if let b = cell.borders.bottom, !mergesDown { bottom = b }

                let text = continues ? nil : cellText(cell, tableParagraph: tableParagraph)
                let insets = NSEdgeInsets(top: marginTop, left: marginLeft, bottom: marginBottom, right: marginRight)
                if let text {
                    let bounds = text.boundingRect(
                        with: CGSize(width: max(1, w - marginLeft - marginRight), height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                    height = max(height, ceil(bounds.height) + marginTop + marginBottom)
                }
                cells.append(
                    TableLayout.Cell(
                        frame: CGRect(x: x, y: 0, width: w, height: 0), text: text,
                        fill: cell.fill.flatMap(Self.color(hex:)), top: top, left: left, bottom: bottom, right: right,
                        textInsets: insets))
            }
            // Empty rows still show one line; Word's row height rules apply on top.
            let (_, run) = styles.resolveParagraphStyle(nil)
            let lineHeight =
                ((characterAttributes(run)[.font] as? NSFont).map { ceil($0.ascender - $0.descender) } ?? 14)
            height = max(height, lineHeight + marginTop + marginBottom)
            if let h = row.height {
                height = row.heightIsExact ? CGFloat(h) : max(height, CGFloat(h))
            }
            for i in cells.indices { cells[i].frame.size.height = height }
            rows.append(TableLayout.Row(height: height, cells: cells))
        }

        let alignment: NSTextAlignment =
            switch props.alignment {
            case "center": .center
            case "right", "end": .right
            default: .left
            }
        // Word places the cell text, not the border, at the indent: the border sits a cell margin to the left.
        let indent = max(0, CGFloat(props.indent ?? 0))
        return TableLayout(width: width, rows: rows, alignment: alignment, indent: alignment == .left ? indent : 0)
    }

    /// A cell's paragraphs as the body would show them, with the table style's paragraph spacing where the
    /// paragraph and its style don't set their own (Word's order: defaults, table style, paragraph style).
    func cellText(_ cell: TableModel.Cell, tableParagraph: ParagraphProperties) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var counter = Numbering.Counter(numbering)
        for content in cell.contents {
            guard case .paragraph(let p) = content else {
                if case .text(let line) = content {
                    let (_, run) = styles.resolveParagraphStyle(nil)
                    out.append(NSAttributedString(string: line + "\n", attributes: characterAttributes(run)))
                }
                continue
            }
            let text = NSMutableAttributedString(
                attributedString: paragraphText(p, leadingBlocks: [], counter: &counter))
            let sets = styles.paragraphStyleSetsSpacing(p.properties.styleId)
            let all = NSRange(location: 0, length: text.length)
            if let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle
            {
                if p.properties.spaceAfter == nil, !sets.after, let after = tableParagraph.spaceAfter {
                    style.paragraphSpacing = CGFloat(after)
                }
                if p.properties.line == nil, !sets.line, let line = tableParagraph.line {
                    var adjusted = p.properties
                    adjusted.line = line
                    adjusted.lineRule = tableParagraph.lineRule
                    let lined = Self.paragraphStyle(adjusted)
                    style.lineHeightMultiple = lined.lineHeightMultiple
                    style.minimumLineHeight = lined.minimumLineHeight
                    style.maximumLineHeight = lined.maximumLineHeight
                }
                text.addAttribute(.paragraphStyle, value: style, range: all)
                // List markers are drawn by the body's layout (`ListMarkerLayout`); inside a drawn cell they'd be lost.
                text.removeAttribute(.libretillaListMarker, range: all)
            }
            out.append(text)
        }
        // No paragraph break (or its space after) below the last line.
        if out.length > 0, (out.string as NSString).character(at: out.length - 1) == 0x0A {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        if let last = out.length > 0 ? out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) : nil,
            let style = (last as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        {
            style.paragraphSpacing = 0
            var r = NSRange()
            _ = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: &r)
            out.addAttribute(.paragraphStyle, value: style, range: r)
        }
        return out
    }

    /// A row drawn on demand (vector, so it prints sharply).
    static func rowImage(_ row: TableLayout.Row, width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: max(1, width), height: max(1, row.height)), flipped: true) { _ in
            for cell in row.cells {
                if let fill = cell.fill {
                    fill.setFill()
                    cell.frame.fill()
                }
                if let text = cell.text {
                    let r = CGRect(
                        x: cell.frame.minX + cell.textInsets.left, y: cell.frame.minY + cell.textInsets.top,
                        width: max(1, cell.frame.width - cell.textInsets.left - cell.textInsets.right),
                        height: max(1, cell.frame.height - cell.textInsets.top - cell.textInsets.bottom))
                    text.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
                func line(_ border: TableBorder?, _ from: CGPoint, _ to: CGPoint) {
                    guard let border, border.isVisible else { return }
                    let path = NSBezierPath()
                    path.move(to: from)
                    path.line(to: to)
                    path.lineWidth = max(0.5, CGFloat(border.width))
                    if border.style == "dashed" { path.setLineDash([3, 2], count: 2, phase: 0) }
                    if border.style == "dotted" { path.setLineDash([1, 1], count: 2, phase: 0) }
                    (border.color.flatMap(color(hex:)) ?? .black).setStroke()
                    path.stroke()
                }
                let f = cell.frame
                // Lines sit just inside the row so neighbouring rows don't clip them.
                let t = f.minY + max(0.25, CGFloat(cell.top?.width ?? 0) / 2)
                let b = f.maxY - max(0.25, CGFloat(cell.bottom?.width ?? 0) / 2)
                let l = f.minX + max(0.25, CGFloat(cell.left?.width ?? 0) / 2)
                let rr = f.maxX - max(0.25, CGFloat(cell.right?.width ?? 0) / 2)
                line(cell.top, CGPoint(x: f.minX, y: t), CGPoint(x: f.maxX, y: t))
                line(cell.bottom, CGPoint(x: f.minX, y: b), CGPoint(x: f.maxX, y: b))
                line(cell.left, CGPoint(x: l, y: f.minY), CGPoint(x: l, y: f.maxY))
                line(cell.right, CGPoint(x: rr, y: f.minY), CGPoint(x: rr, y: f.maxY))
            }
            return true
        }
        image.accessibilityDescription = nil
        return image
    }
}
