import AppKit

// Typing into table cells (backlog 15). A table stays one opaque block drawn as row pictures (ADR 0006); a cell is
// edited in place in a text view laid over it, as a small story of its own: its paragraphs go through the bridge
// like a header's, and only that cell's content is written back into the table's XML.

extension TableModel {
    /// The namespaces a cell's content may use, declared on the wrapper it's parsed in.
    static let cellNamespaces =
        #" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        + #" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        + #" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing""#
        + #" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        + #" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#
        + #" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006""#
        + #" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml""#
        + #" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math""#
        + #" xmlns:v="urn:schemas-microsoft-com:vml""#

    /// Whether a cell can be typed into: it holds paragraphs (with links, pictures, fields…) and nested tables, which
    /// are kept whole (backlog 21), but no other block; and it isn't the continuation of a vertical merge.
    public func canEditInPlace(_ pos: CellPosition) -> Bool {
        guard rows.indices.contains(pos.row), rows[pos.row].cells.indices.contains(pos.cell) else { return false }
        let cell = rows[pos.row].cells[pos.cell]
        return cell.verticalMerge != .continue
            && cell.contents.allSatisfy {
                switch $0 {
                case .paragraph, .table: true
                case .text: false
                }
            }
    }

    /// The cell's paragraphs as a story body, for editing in place; nil if it can't be typed into.
    public func cellBody(_ pos: CellPosition) -> DocumentBody? {
        guard canEditInPlace(pos) else { return nil }
        let cell = rows[pos.row].cells[pos.cell]
        var xml = Data("<w:ftr\(Self.cellNamespaces)>".utf8)
        xml.append(Data(Array([UInt8](self.xml)[cell.contentRange])))
        xml.append(Data("</w:ftr>".utf8))
        guard let body = try? DocumentBody(data: xml, part: "w:tc"), body.readOnlyReason == nil else { return nil }
        return body
    }

    /// The table with the cell's content replaced by `body`'s paragraphs; everything else keeps its bytes.
    public func replacingCell(_ pos: CellPosition, with body: DocumentBody) -> Data? {
        guard canEditInPlace(pos), let doc = try? RawXML.Document(data: body.serialized(), part: "w:tc") else {
            return nil
        }
        var content = doc.slice(doc.root.startTagRange.upperBound..<doc.root.endTagRange.lowerBound)
        // A cell must end with a paragraph.
        if !doc.root.childElements.contains(where: { $0.name == "w:p" }) { content.append(Data("<w:p/>".utf8)) }
        return Self.splicing(xml, [(rows[pos.row].cells[pos.cell].contentRange, content)])
    }
}

extension AttributedStringBridge {
    /// The bridge for a cell's text: the document's, with the cell's width as the room nested tables fit in.
    public func forCell(width: CGFloat) -> AttributedStringBridge {
        AttributedStringBridge(
            styles: styles, numbering: numbering, hyperlinkTargets: hyperlinkTargets, images: images, textWidth: width)
    }
}

/// Where a cell's text sits in its row's picture (backlog 15).
public struct TableCellGeometry: Sendable {
    public var position: TableModel.CellPosition
    /// The cell, and the room for its text (the cell less its margins), in its row picture's coordinates (top-left
    /// origin). A vertically merged cell's height is its row's; its text may run into the rows below.
    public var frame: CGRect
    public var textFrame: CGRect
    /// Its fill, if it has one.
    public var fill: NSColor?
}

extension AttributedStringBridge {
    /// Each row's cells, where they're drawn: what an editor laid over a table needs.
    public func cellGeometry(of model: TableModel) -> [[TableCellGeometry]] {
        let layout = tableLayout(model)
        return layout.rows.enumerated().map { r, row in
            // Layout cells skip cells outside the grid: match them to the model's by grid column.
            row.cells.compactMap { cell in
                guard let index = model.rows[r].cells.firstIndex(where: { $0.gridStart == cell.gridStart }) else {
                    return nil
                }
                let insets = cell.textInsets
                let text = CGRect(
                    x: cell.frame.minX + insets.left, y: cell.frame.minY + insets.top,
                    width: max(1, cell.frame.width - insets.left - insets.right),
                    height: max(1, cell.frame.height - insets.top - insets.bottom))
                return TableCellGeometry(
                    position: .init(row: r, cell: index), frame: cell.frame, textFrame: text, fill: cell.fill)
            }
        }
    }
}
