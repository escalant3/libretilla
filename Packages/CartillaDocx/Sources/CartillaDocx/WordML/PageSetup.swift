import Foundation

/// Page size, orientation and margins of a document, from the final body `w:sectPr`
/// (ECMA-376 Part 1, §17.6.13 `w:pgSz` and §17.6.11 `w:pgMar`). Lengths are in twips (1/20 pt).
///
/// A document with several sections uses the last section's setup for the whole document in
/// Cartilla (display, print and PDF); every section keeps its own `w:sectPr` bytes on save.
public struct PageSetup: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var left: Int
    public var isLandscape: Bool

    public init(width: Int, height: Int, top: Int, right: Int, bottom: Int, left: Int, isLandscape: Bool = false) {
        self.width = width
        self.height = height
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.isLandscape = isLandscape
    }

    /// Word's default when a document has no `w:sectPr`: US Letter, 1 inch margins.
    public static let letter = PageSetup(width: 12240, height: 15840, top: 1440, right: 1440, bottom: 1440, left: 1440)
    /// ISO A4 with Spanish-locale Word's default margins: 2.5 cm top and bottom, 3 cm left and right.
    public static let a4 = PageSetup(width: 11906, height: 16838, top: 1417, right: 1701, bottom: 1417, left: 1701)

    static let twipsPerPoint: CGFloat = 20

    public var pageSize: CGSize {
        CGSize(width: CGFloat(width) / Self.twipsPerPoint, height: CGFloat(height) / Self.twipsPerPoint)
    }

    /// Margins in points. Word allows a negative top/bottom ("text may overlap the header"); the
    /// distance is what matters for layout.
    public var margins: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
        (
            CGFloat(abs(top)) / Self.twipsPerPoint, CGFloat(right) / Self.twipsPerPoint,
            CGFloat(abs(bottom)) / Self.twipsPerPoint, CGFloat(left) / Self.twipsPerPoint
        )
    }

    /// The width of the text column, in points.
    public var textWidth: CGFloat { pageSize.width - margins.left - margins.right }

    /// Reads `w:pgSz` and `w:pgMar` from a `w:sectPr`; missing values fall back to `letter`'s.
    init(sectPr: RawXML.Element?) {
        var setup = PageSetup.letter
        func int(_ e: RawXML.Element?, _ name: String) -> Int? {
            e?.attribute(name).flatMap { Int($0) ?? Double($0).map { Int($0.rounded()) } }
        }
        let size = sectPr?.firstChild(named: "w:pgSz")
        let margins = sectPr?.firstChild(named: "w:pgMar")
        setup.width = int(size, "w:w") ?? setup.width
        setup.height = int(size, "w:h") ?? setup.height
        setup.isLandscape = size?.attribute("w:orient") == "landscape"
        setup.top = int(margins, "w:top") ?? setup.top
        setup.right = int(margins, "w:right") ?? setup.right
        setup.bottom = int(margins, "w:bottom") ?? setup.bottom
        setup.left = int(margins, "w:left") ?? setup.left
        self = setup
    }
}

// MARK: - Reading and writing the final section properties

extension DocumentBody {
    /// The index of the final body `w:sectPr`, if the document has one.
    var sectionPropertiesIndex: Int? {
        blocks.lastIndex { if case .opaque(let o) = $0 { o.isSectionProperties } else { false } }
    }

    /// The document's page setup (Word's default, US Letter, if it has no `w:sectPr`).
    public var pageSetup: PageSetup {
        get {
            guard let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i],
                let doc = try? RawXML.Document(data: o.xml, part: "w:sectPr")
            else { return .letter }
            return PageSetup(sectPr: doc.root)
        }
        set {
            guard newValue != pageSetup else { return }
            var existing: OpaqueBlock?
            if let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i] { existing = o }
            // Only the changed attributes are rewritten; header/footer distances, gutter, paper codes
            // and everything else in the section keep their bytes.
            let old = pageSetup
            var size: [(String, String?)] = []
            if newValue.width != old.width || existing == nil { size.append(("w:w", String(newValue.width))) }
            if newValue.height != old.height || existing == nil { size.append(("w:h", String(newValue.height))) }
            if newValue.isLandscape != old.isLandscape {
                size.append(("w:orient", newValue.isLandscape ? "landscape" : nil))
            }
            var margins: [(String, String?)] = []
            // Keep Word's sign convention for top/bottom when only the size changes.
            func signed(_ value: Int, like current: Int) -> Int { current < 0 ? -abs(value) : value }
            if newValue.top != old.top || existing == nil {
                margins.append(("w:top", String(signed(newValue.top, like: old.top))))
            }
            if newValue.right != old.right || existing == nil { margins.append(("w:right", String(newValue.right))) }
            if newValue.bottom != old.bottom || existing == nil {
                margins.append(("w:bottom", String(signed(newValue.bottom, like: old.bottom))))
            }
            if newValue.left != old.left || existing == nil { margins.append(("w:left", String(newValue.left))) }
            if existing == nil || Self.marginsElementIsMissing(existing!) {
                // `w:pgMar` requires header, footer and gutter; use Word's defaults for a new one.
                margins += [("w:header", "720"), ("w:footer", "720"), ("w:gutter", "0")]
            }

            var edits: [ElementPatch.Edit] = []
            if !size.isEmpty { edits.append(.attributes("w:pgSz", size)) }
            if !margins.isEmpty { edits.append(.attributes("w:pgMar", margins)) }
            guard
                let xml = ElementPatch.apply(
                    edits, to: existing?.xml, wrapper: "w:sectPr", order: ElementPatch.sectionPropertiesOrder),
                let doc = try? RawXML.Document(data: xml, part: "w:sectPr")
            else { return }
            let block = OpaqueBlock(parsing: doc.root, in: doc, leadingTrivia: existing?.leadingTrivia ?? Data())
            if let i = sectionPropertiesIndex {
                blocks[i] = .opaque(block)
            } else {
                blocks.append(.opaque(block))
            }
        }
    }

    private static func marginsElementIsMissing(_ block: OpaqueBlock) -> Bool {
        guard let doc = try? RawXML.Document(data: block.xml, part: "w:sectPr") else { return true }
        return doc.root.firstChild(named: "w:pgMar") == nil
    }
}

extension ElementPatch {
    /// Children of `w:sectPr` (CT_SectPr) in schema order.
    public static let sectionPropertiesOrder = [
        "w:headerReference", "w:footerReference", "w:footnotePr", "w:endnotePr", "w:type", "w:pgSz", "w:pgMar",
        "w:paperSrc", "w:pgBorders", "w:lnNumType", "w:pgNumType", "w:cols", "w:formProt", "w:vAlign", "w:noEndnote",
        "w:titlePg", "w:textDirection", "w:bidi", "w:rtlGutter", "w:docGrid", "w:printerSettings", "w:sectPrChange",
    ]
}
