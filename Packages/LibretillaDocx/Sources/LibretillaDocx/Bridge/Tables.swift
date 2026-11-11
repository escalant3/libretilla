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
        /// In a vertically merged cell (backlog 19), every row holds the merged text: this row shows the part from
        /// `textOffset` down (the heights of the merged rows above it), and `isMerged` says to draw line by line.
        var textOffset: CGFloat = 0
        var isMerged = false
        /// The first grid column the cell covers.
        var gridStart = 0
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
            // What VoiceOver reads for the row (backlog 16): its cells' text.
            attachment.image?.accessibilityDescription = Self.accessibilityText(of: row)
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

    /// The table's layout; `availableWidth` (the text column by default) is the room it scales down to fit.
    func tableLayout(_ model: TableModel, availableWidth: CGFloat? = nil) -> TableLayout {
        let textWidth = availableWidth ?? self.textWidth
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
        /// Vertically merged cells: where each starts (row, cell index), and the height its text needs.
        var merges: [(row: Int, cell: Int, needed: CGFloat)] = []
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
                // Backlog 17: the table style's header row, banding, … (`w:tblStylePr`).
                let conditional = props.conditionalFormat(
                    row: r, of: model.rows.count, columns: start..<end, of: columns.count)
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
                if let b = conditional.borders.top, !continues { top = b }
                if let b = conditional.borders.left { left = b }
                if let b = conditional.borders.right { right = b }
                if let b = conditional.borders.bottom, !mergesDown { bottom = b }
                if let b = cell.borders.top, !continues { top = b }
                if let b = cell.borders.left { left = b }
                if let b = cell.borders.right { right = b }
                if let b = cell.borders.bottom, !mergesDown { bottom = b }

                let text =
                    continues
                    ? nil
                    : cellText(
                        cell, tableParagraph: tableParagraph, conditional: conditional,
                        width: max(1, w - marginLeft - marginRight))
                let insets = NSEdgeInsets(top: marginTop, left: marginLeft, bottom: marginBottom, right: marginRight)
                if let text {
                    let bounds = text.boundingRect(
                        with: CGSize(width: max(1, w - marginLeft - marginRight), height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                    let needed = ceil(bounds.height) + marginTop + marginBottom
                    // A merged cell's text fills its rows together; they grow below if it needs more room.
                    if mergesDown {
                        merges.append((r, cells.count, needed))
                    } else {
                        height = max(height, needed)
                    }
                }
                cells.append(
                    TableLayout.Cell(
                        frame: CGRect(x: x, y: 0, width: w, height: 0), text: text,
                        fill: (cell.fill ?? conditional.fill).flatMap(Self.color(hex:)), top: top, left: left,
                        bottom: bottom, right: right,
                        textInsets: insets, gridStart: start))
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
        for merge in merges { spread(merge, model: model, rows: &rows) }

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

    /// Lays a vertically merged cell's text over its rows: the last one grows if they're too short together (unless
    /// its height is exact), and each continuing cell gets the text and where its part of it starts.
    private func spread(
        _ merge: (row: Int, cell: Int, needed: CGFloat), model: TableModel, rows: inout [TableLayout.Row]
    ) {
        let first = rows[merge.row].cells[merge.cell]
        // The rows the cell spans, with the index of its continuation in each.
        var span: [(row: Int, cell: Int)] = [(merge.row, merge.cell)]
        var r = merge.row + 1
        while r < rows.count,
            let i = rows[r].cells.firstIndex(where: { $0.gridStart == first.gridStart }),
            model.rows[r].cells.contains(where: { $0.gridStart == first.gridStart && $0.verticalMerge == .continue })
        {
            span.append((r, i))
            r += 1
        }
        let total = span.reduce(0) { $0 + rows[$1.row].height }
        if merge.needed > total, let last = span.last, !model.rows[last.row].heightIsExact {
            rows[last.row].height += merge.needed - total
            for i in rows[last.row].cells.indices { rows[last.row].cells[i].frame.size.height = rows[last.row].height }
        }
        guard span.count > 1 else { return }
        var offset: CGFloat = 0
        for (row, cell) in span {
            rows[row].cells[cell].text = first.text
            rows[row].cells[cell].textOffset = offset
            rows[row].cells[cell].isMerged = true
            offset += rows[row].height
        }
    }

    /// A cell's paragraphs as the body would show them, with the table style's paragraph spacing where the
    /// paragraph and its style don't set their own (Word's order: defaults, table style, paragraph style).
    /// `conditional`'s bold, italic and colour apply to text that doesn't set its own.
    func cellText(
        _ cell: TableModel.Cell, tableParagraph: ParagraphProperties,
        conditional: TableConditionalFormat = TableConditionalFormat(), width: CGFloat = 0
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var counter = Numbering.Counter(numbering)
        for content in cell.contents {
            guard case .paragraph(let p) = content else {
                let (_, run) = styles.resolveParagraphStyle(nil)
                if case .text(let line) = content {
                    out.append(NSAttributedString(string: line + "\n", attributes: characterAttributes(run)))
                } else if case .table(let nested) = content {
                    out.append(nestedTable(nested, width: width, attributes: characterAttributes(run)))
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
        applying(conditional, to: out)
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

    /// A table inside a cell, drawn whole as one picture on its own line (backlog 18).
    private func nestedTable(_ model: TableModel, width: CGFloat, attributes: [NSAttributedString.Key: Any])
        -> NSAttributedString
    {
        let layout = tableLayout(model, availableWidth: width > 0 ? width : nil)
        let height = layout.rows.reduce(0) { $0 + $1.height }
        let rows = layout.rows.map { Self.rowImage($0, width: layout.width) }
        let image = NSImage(size: NSSize(width: max(1, layout.width), height: max(1, height)), flipped: true) { _ in
            var y: CGFloat = 0
            for (row, image) in zip(layout.rows, rows) {
                image.draw(in: NSRect(x: 0, y: y, width: layout.width, height: row.height))
                y += row.height
            }
            return true
        }
        image.cacheMode = .never
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: layout.width, height: height)
        var attrs = attributes
        attrs[.attachment] = attachment
        let out = NSMutableAttributedString(string: "\u{FFFC}", attributes: attrs)
        out.append(NSAttributedString(string: "\n", attributes: attributes))
        return out
    }

    /// Gives text without its own bold, italic or colour (direct or from its character style) those of a table
    /// style's conditional format.
    private func applying(_ conditional: TableConditionalFormat, to text: NSMutableAttributedString) {
        guard conditional.bold != nil || conditional.italic != nil || conditional.color != nil else { return }
        let manager = NSFontManager.shared
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let own = (attrs[.libretillaRun] as? RunFormat).map {
                $0.properties.over(styles.resolveCharacterStyle($0.properties.styleId))
            }
            if var font = attrs[.font] as? NSFont {
                if let bold = conditional.bold, own?.bold == nil {
                    font =
                        bold
                        ? manager.convert(font, toHaveTrait: .boldFontMask)
                        : manager.convert(font, toNotHaveTrait: .boldFontMask)
                }
                if let italic = conditional.italic, own?.italic == nil {
                    font =
                        italic
                        ? manager.convert(font, toHaveTrait: .italicFontMask)
                        : manager.convert(font, toNotHaveTrait: .italicFontMask)
                }
                text.addAttribute(.font, value: font, range: range)
            }
            if let color = conditional.color.flatMap(Self.color(hex:)), own?.color == nil {
                text.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    /// A row's cells' text, for VoiceOver: "Apples, 3, Green" (a merged cell's continuation counts as empty).
    static func accessibilityText(of row: TableLayout.Row) -> String {
        row.cells.map { cell in
            cell.isMerged && cell.textOffset > 0
                ? ""
                : (cell.text?.string ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
                    .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: ", ")
    }

    /// A row drawn on demand (vector, so it prints sharply).
    static func rowImage(_ row: TableLayout.Row, width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: max(1, width), height: max(1, row.height)), flipped: true) { _ in
            // On a dark page (Dark Mode), colours chosen for white paper are drawn readable (backlog 28).
            let dark = ReadableColor.isDrawingDark
            for cell in row.cells {
                if let fill = cell.fill {
                    fill.setFill()
                    cell.frame.fill()
                }
                if let original = cell.text {
                    let text = dark ? shownOnDarkPage(original, fill: cell.fill) : original
                    let width = max(1, cell.frame.width - cell.textInsets.left - cell.textInsets.right)
                    if cell.isMerged {
                        drawLines(of: text, cell: cell, width: width)
                    } else {
                        let r = CGRect(
                            x: cell.frame.minX + cell.textInsets.left, y: cell.frame.minY + cell.textInsets.top,
                            width: width,
                            height: max(1, cell.frame.height - cell.textInsets.top - cell.textInsets.bottom))
                        text.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
                    }
                }
                func line(_ border: TableBorder?, _ from: CGPoint, _ to: CGPoint) {
                    guard let border, border.isVisible else { return }
                    let path = NSBezierPath()
                    path.move(to: from)
                    path.line(to: to)
                    path.lineWidth = max(0.5, CGFloat(border.width))
                    if border.style == "dashed" { path.setLineDash([3, 2], count: 2, phase: 0) }
                    if border.style == "dotted" { path.setLineDash([1, 1], count: 2, phase: 0) }
                    let stroke = border.color.flatMap(color(hex:))
                    ((dark ? ReadableColor.onDarkPage(stroke ?? .black, onHighlight: false) : nil) ?? stroke ?? .black)
                        .setStroke()
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
        // Drawn again for each appearance (Dark Mode), not cached.
        image.cacheMode = .never
        return image
    }

    /// Draws the lines of a merged cell's text that belong in this row: those whose middle is in it. Each line is
    /// drawn once, in one row, so a PDF's text holds it once (clipping would leave it in every row's).
    private static func drawLines(of text: NSAttributedString, cell: TableLayout.Cell, width: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        // The text's top, in this row's coordinates.
        let origin = CGPoint(
            x: cell.frame.minX + cell.textInsets.left, y: cell.frame.minY + cell.textInsets.top - cell.textOffset)
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let middle = origin.y + rect.midY
            guard middle >= cell.frame.minY, middle < cell.frame.maxY else { return }
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    /// A cell's text as drawn on a dark page: colours made readable, automatic (black) text light, and text on a
    /// light cell fill kept dark.
    static func shownOnDarkPage(_ text: NSAttributedString, fill: NSColor?) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let onFill = fill?.usingColorSpace(.sRGB).map { ReadableColor.luminance($0) > 0.4 } ?? false
        out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            let color = (value as? NSColor) ?? .black
            let highlighted = onFill || out.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
            if let shown = ReadableColor.onDarkPage(color, onHighlight: highlighted) {
                out.addAttribute(.foregroundColor, value: shown, range: range)
            }
        }
        return out
    }
}
