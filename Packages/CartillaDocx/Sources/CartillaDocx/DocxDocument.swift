import Foundation

// Placeholder document model (M0). Shapes follow bootstrap §5.2; the concrete
// fields are fleshed out in M1 together with the codec chosen in ADR 0002.
// Named `DocxDocument` (not `CartillaDocument`) to avoid clashing with the app's
// NSDocument subclass.

/// An ordered list of blocks plus the document-level tables Word keeps.
public struct DocxDocument: Sendable, Equatable {
    public var blocks: [Block]
    public var styles: [Style]
    public var numbering: [NumberingDefinition]
    public var sections: [SectionProperties]
    public var media: [String: Data]
    /// Every zip part we don't model, kept byte-for-byte for copy-through on save.
    public var preservedParts: [String: Data]

    public init(
        blocks: [Block] = [], styles: [Style] = [], numbering: [NumberingDefinition] = [],
        sections: [SectionProperties] = [], media: [String: Data] = [:],
        preservedParts: [String: Data] = [:]
    ) {
        self.blocks = blocks
        self.styles = styles
        self.numbering = numbering
        self.sections = sections
        self.media = media
        self.preservedParts = preservedParts
    }

    /// Concatenated plain text, one line per paragraph (useful for tests).
    public var plainText: String {
        blocks.compactMap { block -> String? in
            if case .paragraph(let p) = block { return p.text }
            return nil
        }.joined(separator: "\n")
    }
}

public enum Block: Sendable, Equatable {
    case paragraph(Paragraph)
    case table(Table)
    case pageBreak
    /// OOXML we don't understand (e.g. `w:sdt`), re-emitted verbatim.
    case opaque(OpaqueXML)
}

public struct Paragraph: Sendable, Equatable {
    public var styleId: String?
    public var runs: [Run]
    public init(styleId: String? = nil, runs: [Run] = []) {
        self.styleId = styleId
        self.runs = runs
    }
    public var text: String { runs.map(\.text).joined() }
}

public struct Run: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public init(text: String, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
    }
}

public struct Table: Sendable, Equatable {
    public var rows: [[[Block]]]
    public init(rows: [[[Block]]] = []) { self.rows = rows }
}

public struct Style: Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct NumberingDefinition: Sendable, Equatable {
    public var numId: Int
    public init(numId: Int) { self.numId = numId }
}

public struct SectionProperties: Sendable, Equatable {
    public var pageWidthTwips: Int
    public var pageHeightTwips: Int
    public init(pageWidthTwips: Int = 12240, pageHeightTwips: Int = 15840) {
        self.pageWidthTwips = pageWidthTwips
        self.pageHeightTwips = pageHeightTwips
    }
}

/// A verbatim XML fragment plus the part it came from.
public struct OpaqueXML: Sendable, Equatable {
    public var part: String
    public var xml: Data
    public init(part: String, xml: Data) {
        self.part = part
        self.xml = xml
    }
}
