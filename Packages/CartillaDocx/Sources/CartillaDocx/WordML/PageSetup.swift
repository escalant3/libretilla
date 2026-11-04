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

    /// What Cartilla assumes when a document doesn't say (no `w:sectPr`, or no `w:pgSz`/`w:pgMar`):
    /// A4, as Word does in A4 locales. New documents are A4 too (`Resources/Blank.docx`).
    public static let fallback = a4
    /// US Letter, 1 inch margins (Word's US default).
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

    /// Word's exact sizes (portrait, twips) for common papers. AppKit reports paper sizes in whole
    /// points, which would turn A4's 11906 × 16838 into 11900 × 16840.
    static let standardPapers: [(width: Int, height: Int)] = [
        (12240, 15840),  // Letter
        (12240, 20160),  // Legal
        (10440, 15120),  // Executive
        (15840, 24480),  // Tabloid
        (11906, 16838),  // A4
        (8391, 11906),  // A5
        (16838, 23811),  // A3
        (10319, 14571),  // B5 (JIS)
        (9978, 14173),  // B5 (ISO)
    ]

    /// This setup on a paper of `size` points (as AppKit reports it) and orientation, margins unchanged.
    /// The same paper keeps the document's exact twips; a standard paper gets Word's exact size.
    public func withPaper(_ size: CGSize, landscape: Bool) -> PageSetup {
        // The page as it lies: wide for landscape, tall for portrait.
        var w = Int((size.width * Self.twipsPerPoint).rounded())
        var h = Int((size.height * Self.twipsPerPoint).rounded())
        if landscape != (w > h) { (w, h) = (h, w) }
        // Within one point counts as the same size (AppKit's rounding).
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= Int(Self.twipsPerPoint) }
        var setup = self
        setup.isLandscape = landscape
        if near(w, width) && near(h, height) {
            return setup
        }
        if let paper = Self.standardPapers.first(where: { p in
            landscape ? near(w, p.height) && near(h, p.width) : near(w, p.width) && near(h, p.height)
        }) {
            (setup.width, setup.height) = landscape ? (paper.height, paper.width) : (paper.width, paper.height)
        } else {
            (setup.width, setup.height) = (w, h)
        }
        return setup
    }

    /// Reads `w:pgSz` and `w:pgMar` from a `w:sectPr`; missing values come from `fallback`.
    init(sectPr: RawXML.Element?) {
        var setup = PageSetup.fallback
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

    /// The document's page setup (`PageSetup.fallback`, A4, if it has no `w:sectPr`).
    public var pageSetup: PageSetup {
        get {
            guard let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i],
                let doc = try? RawXML.Document(data: o.xml, part: "w:sectPr")
            else { return .fallback }
            return PageSetup(sectPr: doc.root)
        }
        set {
            guard newValue != pageSetup else { return }
            var existing: OpaqueBlock?
            if let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i] { existing = o }
            // Only the changed attributes are rewritten; header/footer distances, gutter, paper codes
            // and everything else in the section keep their bytes.
            let old = pageSetup
            // A size or margins element the section lacks is written whole: Word would otherwise use its
            // own locale's defaults, not the fallback Cartilla showed.
            let writeSize = existing.map { Self.sectionLacks("w:pgSz", $0) } ?? true
            let writeMargins = existing.map { Self.sectionLacks("w:pgMar", $0) } ?? true
            var size: [(String, String?)] = []
            if newValue.width != old.width || writeSize { size.append(("w:w", String(newValue.width))) }
            if newValue.height != old.height || writeSize { size.append(("w:h", String(newValue.height))) }
            if newValue.isLandscape != old.isLandscape {
                size.append(("w:orient", newValue.isLandscape ? "landscape" : nil))
            }
            var margins: [(String, String?)] = []
            // Keep Word's sign convention for top/bottom when only the size changes.
            func signed(_ value: Int, like current: Int) -> Int { current < 0 ? -abs(value) : value }
            if newValue.top != old.top || writeMargins {
                margins.append(("w:top", String(signed(newValue.top, like: old.top))))
            }
            if newValue.right != old.right || writeMargins { margins.append(("w:right", String(newValue.right))) }
            if newValue.bottom != old.bottom || writeMargins {
                margins.append(("w:bottom", String(signed(newValue.bottom, like: old.bottom))))
            }
            if newValue.left != old.left || writeMargins { margins.append(("w:left", String(newValue.left))) }
            if writeMargins {
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

    private static func sectionLacks(_ child: String, _ block: OpaqueBlock) -> Bool {
        guard let doc = try? RawXML.Document(data: block.xml, part: "w:sectPr") else { return true }
        return doc.root.firstChild(named: child) == nil
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
