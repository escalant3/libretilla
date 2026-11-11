import AppKit
import Foundation
import PDFKit
import Testing

@testable import LibretillaDocx

@MainActor
@Suite struct TableTests {
    let codec = OOXMLCodec()

    func firstTable(_ name: String = "04-tables.docx") throws -> (DocxDocument, Int, OpaqueBlock) {
        let doc = try codec.read(try Corpus.data(name))
        let i = try #require(
            doc.body.blocks.firstIndex { if case .opaque(let o) = $0 { o.kind == "w:tbl" } else { false } })
        guard case .opaque(let o) = doc.body.blocks[i] else { throw CocoaError(.featureUnsupported) }
        return (doc, i, o)
    }

    func model(_ xml: Data) throws -> TableModel { try #require(TableModel(xml: xml)) }

    /// The document with block `i` replaced by `xml`, written and read back.
    func replacing(_ doc: DocxDocument, block i: Int, with xml: Data) throws -> DocxDocument {
        var out = doc
        guard case .opaque(let old) = doc.body.blocks[i] else { throw CocoaError(.featureUnsupported) }
        out.body.blocks[i] = .opaque(try #require(OpaqueBlock(xml: xml, leadingTrivia: old.leadingTrivia)))
        let data = try codec.write(out)
        #expect(try PackageChecker.problems(data).isEmpty)
        return try codec.read(data)
    }

    @Test func readsTheGridSpansMergesAndShading() throws {
        let (_, _, o) = try firstTable()
        let t = try model(o.xml)
        #expect(t.columns == [156, 156, 156])
        #expect(t.rows.count == 7)
        #expect(t.rows[0].isHeader)
        #expect(t.rows[0].cells.map(\.text) == ["Name", "Quantity", "Notes"])
        #expect(t.rows[0].cells[0].fill == "D9E2F3")
        #expect(t.rows[4].cells[0].span == 2 && t.rows[4].cells[1].gridStart == 2)
        #expect(t.rows[5].cells[0].verticalMerge == .restart && t.rows[6].cells[0].verticalMerge == .continue)
        #expect(t.properties.styleId == "TableGrid")
        #expect(!t.isSimpleGrid)
        #expect(t.rows.allSatisfy { $0.cells.allSatisfy(\.isEditable) })
    }

    @Test func tableStyleGivesBordersAndCellSpacing() throws {
        let (doc, _, _) = try firstTable()
        let props = doc.styles.tableProperties("TableGrid")
        #expect(props.borders.insideH?.isVisible == true && props.borders.top?.width == 0.5)
        #expect(props.cellMarginLeft == 5.4)  // from TableNormal, through basedOn
        #expect(doc.styles.tableParagraphProperties("TableGrid").spaceAfter == 0)
    }

    @Test func eachRowIsOneLineOfTheTablesBlock() throws {
        let (doc, _, _) = try firstTable()
        let text = AttributedStringBridge(doc).attributedString(for: doc.body)
        var rows: [Int] = []
        text.enumerateAttribute(.libretillaTableRow, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if let i = v as? Int { rows.append(i) }
        }
        #expect(rows == Array(0..<7) + [0])  // the first table's 7 rows, then the nested-table one's single row
        // Rows are separate lines; the whole table (but not the line after it) is one block range.
        let first = (text.string as NSString).range(of: "\u{FFFC}").location
        var whole = NSRange()
        let box = text.attribute(
            .libretillaBlock, at: first, longestEffectiveRange: &whole, in: NSRange(location: 0, length: text.length))
        #expect(box != nil)
        #expect(
            (text.string as NSString).substring(with: whole) == String(repeating: "\u{FFFC}\n", count: 7).dropLast())
        // Row heights follow their content: the header and a one-line row are the same height.
        let a = text.attribute(.attachment, at: first, effectiveRange: nil) as? NSTextAttachment
        #expect(a?.bounds.width == 468)
        #expect((a?.bounds.height ?? 0) > 10 && (a?.bounds.height ?? 0) < 20)
    }

    @Test func editingACellRewritesOnlyThatCell() throws {
        let (doc, i, o) = try firstTable()
        let t = try model(o.xml)
        let xml = t.replacingTexts([
            .init(row: 1, cell: 2): "Very green\nand crisp",
            .init(row: 1, cell: 0): "Apples",  // unchanged
        ])
        let before = String(decoding: o.xml, as: UTF8.self)
        let after = String(decoding: xml, as: UTF8.self)
        #expect(after.contains("<w:t>Very green</w:t>") && after.contains("<w:t>and crisp</w:t>"))
        #expect(
            after.replacingOccurrences(
                of: "<w:t>Very green</w:t></w:r></w:p><w:p><w:r><w:t>and crisp", with: "<w:t>Green") == before)
        let back = try replacing(doc, block: i, with: xml)
        guard case .opaque(let saved) = back.body.blocks[i] else { Issue.record("not a table"); return }
        #expect(try model(saved.xml).rows[1].cells[2].text == "Very green\nand crisp")
    }

    @Test func rowsCanBeAddedAndRemoved() throws {
        let (doc, i, o) = try firstTable()
        let t = try model(o.xml)
        let added = try model(t.addingRow(after: 0))
        #expect(added.rows.count == 8)
        #expect(!added.rows[1].isHeader && added.rows[1].cells.map(\.text) == ["", "", ""])
        #expect(added.rows[1].cells[0].fill == "D9E2F3", "the copy keeps cell shading")

        // Removing the row where a vertical merge starts restarts it in the next row.
        let removed = try model(t.removingRow(5))
        #expect(removed.rows.count == 6)
        #expect(removed.rows[5].cells[0].verticalMerge == .restart)
        _ = try replacing(doc, block: i, with: t.removingRow(5))
        #expect(try model(t.removingRow(0)).rows[0].cells[0].text == "Apples")
    }

    @Test func columnsCanBeAddedAndRemovedInASimpleGrid() throws {
        let xml = TableModel.newTable(rows: 2, columns: 2, width: 400, styleId: "TableGrid")
        let t = try model(xml)
        #expect(t.isSimpleGrid && t.columns == [200, 200])
        let wider = try model(t.addingColumn(after: 0))
        #expect(wider.columns.count == 3 && abs(wider.columns.reduce(0, +) - 400) < 0.1)
        #expect(wider.rows.allSatisfy { $0.cells.count == 3 })
        let narrower = try model(wider.removingColumn(2))
        #expect(narrower.rows.allSatisfy { $0.cells.count == 2 } && narrower.columns.count == 2)
        // Not on a table with spans.
        let (_, _, o) = try firstTable()
        #expect(try model(o.xml).addingColumn(after: 0) == o.xml)
    }

    @Test func newTablesOpenAsTables() throws {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        let xml = TableModel.newTable(rows: 3, columns: 4, width: 468, styleId: "TableGrid")
        doc.body.blocks.insert(.opaque(try #require(OpaqueBlock(xml: xml))), at: 1)
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        let back = try codec.read(data)
        let text = AttributedStringBridge(back).attributedString(for: back.body)
        var rows = 0
        text.enumerateAttribute(.libretillaTableRow, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if v != nil { rows += 1 }
        }
        #expect(rows == 3)
        // Without a style, the table carries its own borders.
        let plain = String(decoding: TableModel.newTable(rows: 1, columns: 1, width: 100, styleId: nil), as: UTF8.self)
        #expect(plain.contains("<w:tblBorders>"))
    }

    @Test func unreadableTablesStillShowAsAPlaceholder() throws {
        let xml = Data(
            #"<w:tbl><w:tblPr/><w:sdt><w:sdtContent><w:tr><w:tc><w:p/></w:tc></w:tr></w:sdtContent></w:sdt></w:tbl>"#
                .utf8)
        #expect(TableModel(xml: xml) == nil)
    }

    // MARK: Table styles (backlog 17)

    /// The tables of a document, laid out by its bridge.
    func layouts(_ name: String) throws -> [TableLayout] {
        let doc = try codec.read(try Corpus.data(name))
        let bridge = AttributedStringBridge(doc)
        return try doc.body.blocks.compactMap { block in
            guard case .opaque(let o) = block, o.kind == "w:tbl" else { return nil }
            return bridge.tableLayout(try model(o.xml))
        }
    }

    func fill(_ cell: TableLayout.Cell) -> String? {
        guard let c = cell.fill?.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
    }

    func isBold(_ cell: TableLayout.Cell) -> Bool {
        guard let font = cell.text?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    @Test func tableStylesShadeHeaderRowsAndBands() throws {
        let tables = try layouts("17-table-styles.docx")
        #expect(tables.count == 2)
        let on = tables[0]
        // The header row: blue, with white bold text.
        #expect(on.rows[0].cells.map(fill) == ["4472C4", "4472C4", "4472C4"])
        #expect(on.rows[0].cells.allSatisfy(isBold))
        let white = on.rows[0].cells[1].text?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(white?.usingColorSpace(.sRGB)?.whiteComponentApproximately == 1)
        // Bands from the first row after the header: odd ones light blue, a cell's own shading wins.
        #expect(on.rows[1].cells.map(fill) == ["D9E2F3", "D9E2F3", "D9E2F3"])
        #expect(on.rows[2].cells.map(fill) == [nil, nil, nil])
        #expect(on.rows[3].cells.map(fill) == ["D9E2F3", "D9E2F3", "FFF2CC"])
        // The first column is bold; the others aren't.
        #expect(isBold(on.rows[2].cells[0]) && !isBold(on.rows[2].cells[1]))

        let off = tables[1]
        #expect(off.rows.allSatisfy { $0.cells.allSatisfy { fill($0) == nil && !isBold($0) } })
    }

    @Test func tableLookReadsWord2007BitMasks() throws {
        let xml = Data(#"<w:tblLook xmlns:w="w" w:val="04A0"/>"#.utf8)
        let look = TableLook(try RawXML.Document(data: xml, part: "t").root)
        #expect(look.firstRow && look.firstColumn && !look.lastRow && !look.lastColumn)
        #expect(look.rowBands && !look.columnBands)
    }

    // MARK: Dark Mode (backlog 28)

    @Test func cellTextIsReadableOnADarkPage() {
        let black = NSAttributedString(string: "a", attributes: [.foregroundColor: NSColor.black])
        let automatic = NSAttributedString(string: "a")
        for text in [black, automatic] {
            let shown = AttributedStringBridge.shownOnDarkPage(text, fill: nil)
            #expect(shown.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .textColor)
        }
        let onLight = AttributedStringBridge.shownOnDarkPage(
            black, fill: NSColor(srgbRed: 1, green: 0.95, blue: 0.8, alpha: 1))
        #expect(onLight.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .black)
    }

    /// The brightest pixel of a table row drawn in `appearance` (its text, on a transparent background).
    func brightest(_ image: NSImage, in appearance: NSAppearance.Name) -> CGFloat {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        var best: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                best = max(best, c.brightnessComponent)
            }
        }
        return best
    }

    @Test func tableRowsAreDrawnForTheAppearance() throws {
        let doc = try codec.read(try Corpus.data("04-tables.docx"))
        let (_, _, o) = try firstTable()
        let layout = AttributedStringBridge(doc).tableLayout(try model(o.xml))
        let row = AttributedStringBridge.rowImage(layout.rows[1], width: layout.width)  // "Apples", no fill
        #expect(brightest(row, in: .aqua) < 0.3, "black text and borders on white paper")
        #expect(brightest(row, in: .darkAqua) > 0.7, "light text and borders on a dark page")
    }

    // MARK: Vertical merges (backlog 19)

    @Test func mergedCellTextSpansItsRows() throws {
        let doc = try codec.read(try Corpus.data("04-tables.docx"))
        let words = (1...24).map { "word\($0)" }
        func tc(_ text: String, merge: String?) -> String {
            let vMerge = merge.map { $0.isEmpty ? "<w:vMerge/>" : "<w:vMerge w:val=\"\($0)\"/>" } ?? ""
            return "<w:tc><w:tcPr><w:tcW w:w=\"1440\" w:type=\"dxa\"/>\(vMerge)</w:tcPr>"
                + "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:tc>"
        }
        let xml =
            #"<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:tblPr/>"#
            + #"<w:tblGrid><w:gridCol w:w="1440"/><w:gridCol w:w="1440"/></w:tblGrid>"#
            + "<w:tr>" + tc(words.joined(separator: " "), merge: "restart") + tc("b1", merge: nil) + "</w:tr>"
            + "<w:tr>" + tc("", merge: "") + tc("b2", merge: nil) + "</w:tr></w:tbl>"
        let layout = AttributedStringBridge(doc).tableLayout(try model(Data(xml.utf8)))
        #expect(layout.rows[0].height < 20, "the first row keeps its own one line")
        #expect(layout.rows[1].height > 3 * layout.rows[0].height, "the last merged row grows for the text")

        // Each row draws its own lines of the merged text, so a PDF holds each word once.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: layout.width, height: 400)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y: CGFloat = 400
        for row in layout.rows {
            y -= row.height
            AttributedStringBridge.rowImage(row, width: layout.width).draw(
                in: NSRect(x: 0, y: y, width: layout.width, height: row.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        let text = try #require(PDFDocument(data: data as Data)?.string)
        let found = text.matches(of: try Regex("word[0-9]+")).map { String(text[$0.range]) }
        #expect(found.sorted() == words.sorted(), "each word once: \(text)")
    }

    // MARK: Nested tables (backlog 18)

    @Test func nestedTablesAreDrawnAsTables() throws {
        let doc = try codec.read(try Corpus.data("04-tables.docx"))
        let nestedBlock = try #require(
            doc.body.blocks.compactMap { b -> OpaqueBlock? in
                if case .opaque(let o) = b, o.kind == "w:tbl" { o } else { nil }
            }.last)
        let outer = try model(nestedBlock.xml)
        guard case .table(let inner) = outer.rows[0].cells[1].contents.first else {
            Issue.record("the cell's content is a table")
            return
        }
        #expect(inner.rows[0].cells.map(\.text) == ["in-1", "in-2"])
        #expect(outer.rows[0].cells[1].text.contains("in-1 · in-2"), "the cell editor still shows a line")
        let layout = AttributedStringBridge(doc).tableLayout(outer)
        let text = try #require(layout.rows[0].cells[1].text)
        let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.bounds.width ?? 0 > 100, "the inner table, as wide as its columns")
        #expect(attachment?.bounds.height ?? 0 > 10)
    }

    /// Backlog 16: VoiceOver reads a table row as its cells' text.
    @Test func tableRowsDescribeTheirCells() throws {
        let doc = try codec.read(try Corpus.data("04-tables.docx"))
        let (_, _, o) = try firstTable()
        let text = try #require(AttributedStringBridge(doc).tableText(o, leadingBlocks: []))
        let rows = (0..<text.length).compactMap {
            (text.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment)?.image?
                .accessibilityDescription
        }
        #expect(rows.first == "Name, Quantity, Notes")
        #expect(rows[1] == "Apples, 3, Green")
    }

    // MARK: Typing into cells (backlog 15)

    @Test func cellsRoundTripThroughTheBridge() throws {
        let (doc, _, o) = try firstTable()
        let table = try model(o.xml)
        let bridge = AttributedStringBridge(doc)
        let pos = TableModel.CellPosition(row: 1, cell: 2)  // "Green"
        let body = try #require(table.cellBody(pos))
        let text = NSMutableAttributedString(attributedString: bridge.attributedString(for: body))
        #expect(text.string == "Green\n")
        // Unchanged: the table's bytes are too.
        let same = try #require(table.replacingCell(pos, with: bridge.body(from: text, base: body).body))
        #expect(same == table.xml)

        text.replaceCharacters(in: NSRange(location: 5, length: 0), with: " and crisp")
        bridge.apply(.bold(true), to: text, range: NSRange(location: 0, length: 5))
        let edited = try model(try #require(table.replacingCell(pos, with: bridge.body(from: text, base: body).body)))
        #expect(edited.rows[1].cells[2].text == "Green and crisp")
        #expect(edited.rows[1].cells[2].paragraphs.first?.inlines.count == 2, "a bold run, then a plain one")
        let xml = String(decoding: edited.xml, as: UTF8.self)
        #expect(xml.contains("<w:b/>"))
        // Every other cell keeps its bytes.
        for (r, row) in table.rows.enumerated() {
            for (c, cell) in row.cells.enumerated() where (r, c) != (1, 2) {
                #expect(cell.text == edited.rows[r].cells[c].text)
            }
        }
        #expect(!table.canEditInPlace(.init(row: 6, cell: 0)), "a merge's continuation")
    }

    // MARK: Cells with links and nested tables (backlog 21)

    @Test func cellsWithLinksAreTypedIntoKeepingTheLink() throws {
        let doc = try codec.read(try Corpus.data("06-hyperlinks.docx"))
        let rid = try #require(doc.hyperlinkTargets.first { $0.value == "https://example.com/" }?.key)
        let xml =
            #"<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" "#
            + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:tblPr/>"#
            + #"<w:tblGrid><w:gridCol w:w="4000"/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t xml:space="preserve">See </w:t>"#
            + #"</w:r><w:hyperlink r:id="\#(rid)"><w:r><w:t>the site</w:t></w:r></w:hyperlink></w:p></w:tc></w:tr></w:tbl>"#
        let table = try model(Data(xml.utf8))
        let pos = TableModel.CellPosition(row: 0, cell: 0)
        #expect(table.canEditInPlace(pos))
        let bridge = AttributedStringBridge(doc)
        let body = try #require(table.cellBody(pos))
        let text = NSMutableAttributedString(attributedString: bridge.attributedString(for: body))
        #expect(try #require(table.replacingCell(pos, with: bridge.body(from: text, base: body).body)) == table.xml)
        text.insert(NSAttributedString(string: "Please "), at: 0)
        let edited = String(
            decoding: try #require(table.replacingCell(pos, with: bridge.body(from: text, base: body).body)),
            as: UTF8.self)
        #expect(edited.contains("Please See "))
        #expect(edited.contains(#"<w:hyperlink r:id="\#(rid)"><w:r><w:t>the site</w:t></w:r></w:hyperlink>"#))
    }

    @Test func cellsWithNestedTablesKeepThemWhole() throws {
        let doc = try codec.read(try Corpus.data("04-tables.docx"))
        let outerBlock = try #require(
            doc.body.blocks.compactMap { b -> OpaqueBlock? in
                if case .opaque(let o) = b, o.kind == "w:tbl" { o } else { nil }
            }.last)
        let outer = try model(outerBlock.xml)
        let pos = TableModel.CellPosition(row: 0, cell: 1)
        #expect(outer.canEditInPlace(pos))
        let bridge = AttributedStringBridge(doc).forCell(width: 200)
        let body = try #require(outer.cellBody(pos))
        let text = NSMutableAttributedString(attributedString: bridge.attributedString(for: body))
        #expect(text.attribute(.libretillaBlock, at: 0, effectiveRange: nil) != nil, "the nested table, kept whole")
        #expect(try #require(outer.replacingCell(pos, with: bridge.body(from: text, base: body).body)) == outer.xml)
        // Typing in the paragraph after it.
        text.replaceCharacters(in: NSRange(location: text.length - 1, length: 0), with: "Below the inner table")
        let edited = try model(try #require(outer.replacingCell(pos, with: bridge.body(from: text, base: body).body)))
        guard case .table(let inner) = edited.rows[0].cells[1].contents.first else {
            Issue.record("still a nested table")
            return
        }
        #expect(inner.rows[0].cells.map(\.text) == ["in-1", "in-2"])
        #expect(edited.rows[0].cells[1].paragraphs.last?.text == "Below the inner table")
    }
}

extension NSColor {
    fileprivate var whiteComponentApproximately: CGFloat {
        ((redComponent + greenComponent + blueComponent) / 3 * 100).rounded() / 100
    }
}
