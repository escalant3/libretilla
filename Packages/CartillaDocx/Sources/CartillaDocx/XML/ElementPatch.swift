import Foundation

/// Lossless edits to one small XML element, such as a `<w:rPr>` or `<w:pPr>` (ADR 0002).
///
/// Only the children an edit names are touched. Everything else, including children Cartilla
/// doesn't understand, keeps its exact bytes and position. New children go in schema order, so
/// Word never sees an out-of-sequence element.
public enum ElementPatch {
    public enum Edit: Sendable, Equatable {
        /// Removes every child with this name.
        case remove(String)
        /// Replaces the child with this name by `xml` (a complete element), or inserts it.
        case replace(String, xml: String)
        /// Sets (non-nil) or removes (nil) attributes of the child with this name, creating it if
        /// needed. A child left with no attributes is removed.
        case attributes(String, [(String, String?)])

        public static func == (a: Edit, b: Edit) -> Bool {
            switch (a, b) {
            case (.remove(let x), .remove(let y)): x == y
            case (.replace(let x, let xx), .replace(let y, let yy)): x == y && xx == yy
            case (.attributes(let x, let xa), .attributes(let y, let ya)):
                x == y && xa.map(\.0) == ya.map(\.0) && xa.map(\.1) == ya.map(\.1)
            default: false
            }
        }

        var childName: String {
            switch self {
            case .remove(let n), .replace(let n, _), .attributes(let n, _): n
            }
        }
    }

    /// Applies `edits` to `element` (nil means "absent": an empty `<wrapper>` is created if an edit
    /// adds something). Returns nil when the element ends up with no children and no attributes.
    public static func apply(_ edits: [Edit], to element: Data?, wrapper: String, order: [String]) -> Data? {
        // Byte offsets below assume a zero-based buffer, which a `Data` slice isn't.
        var current = Data([UInt8](element ?? Data("<\(wrapper)></\(wrapper)>".utf8)))
        for edit in edits {
            current = apply(edit, to: current, order: order) ?? current
        }
        guard let doc = try? RawXML.Document(data: current, part: wrapper) else { return current }
        if doc.root.childElements.isEmpty, doc.root.attributes.isEmpty { return nil }
        return current
    }

    static func apply(_ edit: Edit, to element: Data, order: [String]) -> Data? {
        guard let doc = try? RawXML.Document(data: element, part: "patch") else { return nil }
        var root = doc.root
        var bytes = element
        // A self-closing wrapper (`<w:rPr/>`) gets an explicit end tag so children can be added.
        if root.endTagRange.isEmpty {
            let name = root.name
            var open = doc.slice(root.startTagRange)
            // Drop "/>" (and any space before it), then close.
            while let last = open.last, last == UInt8(ascii: ">") || last == UInt8(ascii: "/") || last == 0x20 {
                open.removeLast()
            }
            bytes = open + Data(">".utf8) + Data("</\(name)>".utf8)
            guard let reparsed = try? RawXML.Document(data: bytes, part: "patch") else { return nil }
            root = reparsed.root
        }
        let name = edit.childName
        let matches = root.childElements(named: name)

        switch edit {
        case .remove:
            return removing(matches.map(\.range), from: bytes)
        case .replace(_, let xml):
            if let first = matches.first {
                var out = removing(matches.dropFirst().map(\.range), from: bytes)
                out.replaceSubrange(first.range, with: Data(xml.utf8))
                return out
            }
            return inserting(Data(xml.utf8), named: name, into: root, bytes: bytes, order: order)
        case .attributes(_, let changes):
            if let first = matches.first {
                var attrs = first.attributes.map { ($0.name, $0.value) }
                for (key, value) in changes {
                    if let i = attrs.firstIndex(where: { $0.0 == key }) {
                        if let value { attrs[i].1 = value } else { attrs.remove(at: i) }
                    } else if let value {
                        attrs.append((key, value))
                    }
                }
                var out = removing(matches.dropFirst().map(\.range), from: bytes)
                if attrs.isEmpty && first.childElements.isEmpty {
                    out.removeSubrange(first.range)
                    return out
                }
                let selfClosing = first.endTagRange.isEmpty
                out.replaceSubrange(
                    first.startTagRange, with: Data(startTag(name, attrs, selfClosing: selfClosing).utf8))
                return out
            }
            let attrs = changes.compactMap { k, v in v.map { (k, $0) } }
            guard !attrs.isEmpty else { return bytes }
            return inserting(
                Data(startTag(name, attrs, selfClosing: true).utf8), named: name, into: root, bytes: bytes, order: order
            )
        }
    }

    static func startTag(_ name: String, _ attrs: [(String, String)], selfClosing: Bool) -> String {
        var s = "<" + name
        for (k, v) in attrs { s += " \(k)=\"\(RawXML.escapeAttribute(v))\"" }
        return s + (selfClosing ? "/>" : ">")
    }

    /// Removes byte ranges (which must not overlap), last first so earlier offsets stay valid.
    static func removing(_ ranges: [Range<Int>], from bytes: Data) -> Data {
        var out = bytes
        for r in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { out.removeSubrange(r) }
        return out
    }

    /// Inserts `xml` right after the last child that comes earlier in `order`. With none, it goes
    /// first. Children not in `order` (extensions like `w14:*`, which follow the schema's own) never
    /// anchor an insertion.
    static func inserting(_ xml: Data, named name: String, into root: RawXML.Element, bytes: Data, order: [String])
        -> Data
    {
        let rank = order.firstIndex(of: name) ?? order.count
        var at = root.startTagRange.upperBound
        for child in root.childElements {
            if let r = order.firstIndex(of: child.name), r <= rank { at = child.range.upperBound }
        }
        var out = bytes
        out.insert(contentsOf: xml, at: at)
        return out
    }
}

// MARK: - Schema order (ECMA-376 Part 1, §17.3.1.26 and §17.3.2.28)

extension ElementPatch {
    /// Children of `w:rPr` (CT_RPr) in schema order.
    public static let runPropertiesOrder = [
        "w:rStyle", "w:rFonts", "w:b", "w:bCs", "w:i", "w:iCs", "w:caps", "w:smallCaps", "w:strike", "w:dstrike",
        "w:outline", "w:shadow", "w:emboss", "w:imprint", "w:noProof", "w:snapToGrid", "w:vanish", "w:webHidden",
        "w:color", "w:spacing", "w:w", "w:kern", "w:position", "w:sz", "w:szCs", "w:highlight", "w:u", "w:effect",
        "w:bdr", "w:shd", "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang", "w:eastAsianLayout",
        "w:specVanish", "w:oMath", "w:rPrChange",
    ]

    /// Children of `w:pPr` (CT_PPr) in schema order.
    public static let paragraphPropertiesOrder = [
        "w:pStyle", "w:keepNext", "w:keepLines", "w:pageBreakBefore", "w:framePr", "w:widowControl", "w:numPr",
        "w:suppressLineNumbers", "w:pBdr", "w:shd", "w:tabs", "w:suppressAutoHyphens", "w:kinsoku", "w:wordWrap",
        "w:overflowPunct", "w:topLinePunct", "w:autoSpaceDE", "w:autoSpaceDN", "w:bidi", "w:adjustRightInd",
        "w:snapToGrid", "w:spacing", "w:ind", "w:contextualSpacing", "w:mirrorIndents", "w:suppressOverlap", "w:jc",
        "w:textDirection", "w:textAlignment", "w:textboxTightWrap", "w:outlineLvl", "w:divId", "w:cnfStyle",
        "w:rPr", "w:sectPr", "w:pPrChange",
    ]
}
