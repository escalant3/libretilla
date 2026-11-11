import Foundation

public let wordprocessingMLNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

/// The body of the main document part (`word/document.xml`), split into blocks; or the content of a
/// header or footer part (`w:hdr`, `w:ftr`), which holds the same block content.
///
/// Lossless by construction (ADR 0002): `prefix` holds every byte up to and including the
/// `<w:body>` (or `<w:hdr>`/`<w:ftr>`) start tag, `suffix` everything from its end tag on, and each
/// block keeps its source bytes. A block whose `original` is still set is written back verbatim.
public struct DocumentBody: Sendable {
    public var prefix: Data
    public var blocks: [Block]
    /// Whitespace/comments between the last block and `</w:body>`.
    public var trailingTrivia: Data
    public var suffix: Data
    /// Why the document can't be edited safely, if it can't (it then opens read-only).
    public var readOnlyReason: String?

    public init(data: Data, part: String = "word/document.xml") throws {
        let doc = try RawXML.Document(data: data, part: part)
        let root = doc.root
        let body: RawXML.Element
        let expected: String
        if root.name.hasSuffix(":hdr") || root.name.hasSuffix(":ftr") {
            body = root
            expected = root.name.hasSuffix(":hdr") ? "w:hdr" : "w:ftr"
        } else {
            guard root.name.hasSuffix("document"),
                let b = root.firstChild(named: "w:body") ?? Self.anyBody(root)
            else { throw DocxCodecError.missingPart("\(part): <w:body>") }
            body = b
            expected = "w:body"
        }

        if root.attribute("xmlns:w") != wordprocessingMLNamespace || body.name != expected {
            readOnlyReason = "it uses Strict Open XML or a non-standard namespace prefix"
        }
        prefix = doc.slice(0..<body.startTagRange.upperBound)
        suffix = doc.slice(body.endTagRange.lowerBound..<doc.bytes.count)
        if body.endTagRange.isEmpty {
            // `<w:body/>` or `<w:hdr …/>`: no content. Synthesize an open/close pair so blocks can be added.
            var open = doc.slice(body.startTagRange)
            while let last = open.last, last == UInt8(ascii: ">") || last == UInt8(ascii: "/") || last == 0x20 {
                open.removeLast()
            }
            prefix = doc.slice(0..<body.range.lowerBound) + open + Data(">".utf8)
            suffix = Data("</\(body.name)>".utf8) + doc.slice(body.range.upperBound..<doc.bytes.count)
        }

        var blocks: [Block] = []
        var triviaStart: Int?
        for node in body.children {
            switch node {
            case .text, .other:
                if triviaStart == nil { triviaStart = node.range.lowerBound }
            case .element(let e):
                let trivia = triviaStart.map { doc.slice($0..<e.range.lowerBound) } ?? Data()
                triviaStart = nil
                if e.name == "w:p" {
                    blocks.append(.paragraph(Paragraph(parsing: e, in: doc, leadingTrivia: trivia)))
                } else {
                    blocks.append(.opaque(OpaqueBlock(parsing: e, in: doc, leadingTrivia: trivia)))
                }
            }
        }
        self.blocks = blocks
        trailingTrivia = triviaStart.map { doc.slice($0..<body.endTagRange.lowerBound) } ?? Data()
    }

    private static func anyBody(_ root: RawXML.Element) -> RawXML.Element? {
        root.childElements.first { $0.name.hasSuffix(":body") || $0.name == "body" }
    }

    public func serialized() -> Data {
        var out = prefix
        for block in blocks { out.append(block.serialized()) }
        out.append(trailingTrivia)
        out.append(suffix)
        return out
    }

    /// Concatenated visible text, one line per paragraph or table/content control (tests, word count).
    public var plainText: String {
        blocks.compactMap {
            switch $0 {
            case .paragraph(let p): p.text
            case .opaque(let o): o.visibleText.isEmpty ? nil : o.visibleText
            }
        }.joined(separator: "\n")
    }
}

public enum Block: Sendable {
    case paragraph(Paragraph)
    /// Body content Libretilla doesn't model yet (tables, block content controls, the final
    /// `w:sectPr`, …), kept verbatim.
    case opaque(OpaqueBlock)

    public func serialized() -> Data {
        switch self {
        case .paragraph(let p): p.serialized()
        case .opaque(let o): o.leadingTrivia + o.xml
        }
    }
}

// MARK: - Paragraph

public struct Paragraph: Sendable {
    public var properties: ParagraphProperties
    /// Raw `<w:pPr>…</w:pPr>`, or nil.
    public var propertiesXML: Data?
    /// `propertiesXML` without its `<w:sectPr>` (only set when it has one).
    public var propertiesXMLWithoutSectionBreak: Data?
    public var inlines: [Inline]
    /// Exact source bytes (`<w:p>…</w:p>`). While set, `serialized()` returns them verbatim.
    public var original: Data?
    public var leadingTrivia: Data

    public init(
        properties: ParagraphProperties = ParagraphProperties(), propertiesXML: Data? = nil, inlines: [Inline] = []
    ) {
        self.properties = properties
        self.propertiesXML = propertiesXML
        self.propertiesXMLWithoutSectionBreak = nil
        self.inlines = inlines
        self.original = nil
        self.leadingTrivia = Data()
    }

    init(parsing p: RawXML.Element, in doc: RawXML.Document, leadingTrivia: Data) {
        let pPr = p.firstChild(named: "w:pPr")
        properties = ParagraphProperties(pPr)
        propertiesXML = pPr.map { doc.slice($0.range) }
        propertiesXMLWithoutSectionBreak = nil
        if let pPr, let sect = pPr.firstChild(named: "w:sectPr") {
            propertiesXMLWithoutSectionBreak =
                doc.slice(pPr.range.lowerBound..<sect.range.lowerBound)
                + doc.slice(sect.range.upperBound..<pPr.range.upperBound)
        }
        inlines = p.childElements.filter { $0.name != "w:pPr" }.map { Inline(parsing: $0, in: doc) }
        original = doc.slice(p.range)
        self.leadingTrivia = leadingTrivia
    }

    public var text: String { inlines.map(\.visibleText).joined() }

    /// A copy that will be re-serialized from its parts rather than written verbatim.
    public func edited() -> Paragraph {
        var p = self
        p.original = nil
        p.leadingTrivia = Data()
        return p
    }

    public func serialized(keepSectionBreak: Bool = true) -> Data {
        if let original { return leadingTrivia + original }
        var out = Data("<w:p>".utf8)
        if let pPr = keepSectionBreak ? propertiesXML : (propertiesXMLWithoutSectionBreak ?? propertiesXML) {
            out.append(pPr)
        }
        for inline in inlines { out.append(inline.serialized()) }
        out.append(Data("</w:p>".utf8))
        return out
    }
}

public enum Inline: Sendable {
    case run(Run)
    /// A link holding only plain runs.
    case hyperlink(Hyperlink)
    /// Paragraph content Libretilla doesn't model yet (hyperlinks, fields, drawings, bookmarks,
    /// tracked changes, inline content controls, …), kept verbatim.
    case opaque(OpaqueInline)

    init(parsing e: RawXML.Element, in doc: RawXML.Document) {
        if e.name == "w:r", let run = Run(parsing: e, in: doc) {
            self = .run(run)
        } else if e.name == "w:hyperlink", let link = Hyperlink(parsing: e, in: doc) {
            self = .hyperlink(link)
        } else {
            self = .opaque(OpaqueInline(parsing: e, in: doc))
        }
    }

    public var visibleText: String {
        switch self {
        case .run(let r): r.text
        case .hyperlink(let l): l.text
        case .opaque(let o): o.visibleText
        }
    }

    public func serialized() -> Data {
        switch self {
        case .run(let r): r.serialized()
        case .hyperlink(let l): l.serialized()
        case .opaque(let o): o.xml
        }
    }
}

/// A run of plain text with formatting. Tabs are `\t`, line breaks `U+2028` and page breaks `U+000C`.
public struct Run: Sendable {
    public var properties: RunProperties
    /// Raw `<w:rPr>…</w:rPr>`, or nil.
    public var propertiesXML: Data?
    public var text: String

    public static let lineBreak: Character = "\u{2028}"
    /// `<w:br w:type="page"/>`.
    public static let pageBreak: Character = "\u{000C}"

    public init(text: String, properties: RunProperties = RunProperties(), propertiesXML: Data? = nil) {
        self.text = text
        self.properties = properties
        self.propertiesXML = propertiesXML
    }

    /// Parses `w:r` if it only holds text, tabs, line and page breaks; nil otherwise (it becomes opaque).
    init?(parsing r: RawXML.Element, in doc: RawXML.Document) {
        var text = ""
        var rPr: RawXML.Element?
        for node in r.children {
            switch node {
            case .text(let t) where t.isWhitespace: continue
            case .text, .other: return nil
            case .element(let e):
                switch e.name {
                case "w:rPr": rPr = e
                case "w:t": text += e.text
                case "w:tab": text += "\t"
                case "w:br" where e.attribute("w:type") == nil || e.attribute("w:type") == "textWrapping":
                    guard e.attribute("w:clear") == nil else { return nil }
                    text.append(Self.lineBreak)
                case "w:br" where e.attribute("w:type") == "page":
                    guard e.attribute("w:clear") == nil else { return nil }
                    text.append(Self.pageBreak)
                case "w:cr": text.append(Self.lineBreak)
                case "w:lastRenderedPageBreak": continue  // layout hint; Word regenerates it
                default: return nil
                }
            }
        }
        self.properties = RunProperties(rPr)
        self.propertiesXML = rPr.map { doc.slice($0.range) }
        self.text = text
    }

    public func serialized() -> Data {
        guard !text.isEmpty else { return Data() }
        var out = Data("<w:r>".utf8)
        if let propertiesXML { out.append(propertiesXML) }
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            let preserve = segment.first == " " || segment.last == " " || segment.contains("  ")
            out.append(Data((preserve ? "<w:t xml:space=\"preserve\">" : "<w:t>").utf8))
            out.append(Data(RawXML.escapeText(segment).utf8))
            out.append(Data("</w:t>".utf8))
            segment = ""
        }
        for ch in text {
            switch ch {
            case "\t":
                flush()
                out.append(Data("<w:tab/>".utf8))
            case Self.lineBreak, "\n", "\r":
                flush()
                out.append(Data("<w:br/>".utf8))
            case Self.pageBreak:
                flush()
                out.append(Data("<w:br w:type=\"page\"/>".utf8))
            default:
                segment.append(ch)
            }
        }
        flush()
        out.append(Data("</w:r>".utf8))
        return out
    }
}

/// Verbatim paragraph-level content.
public struct OpaqueInline: Sendable {
    public enum Display: Sendable, Equatable {
        /// Shows its text (hyperlinks, simple fields, inline content controls, insertions).
        case text(String)
        /// Shows as one object character (drawings, text boxes, equations, footnote references).
        case object(label: String)
        /// Takes no space (bookmarks, comment ranges, field begin/end markers, deletions).
        case invisible
    }

    public var kind: String
    public var xml: Data
    public var display: Display
    /// Formatting of the first run inside, used to display its text.
    public var displayProperties: RunProperties
    /// Can be dropped without changing the document's meaning (`w:proofErr`).
    public var isDroppable: Bool
    /// The picture a drawing shows, when it's a single embedded image.
    public var image: ImageReference?
    /// A picture inserted in Libretilla, written as a new media part when saving (see `OOXMLCodec`).
    public var newMedia: NewMedia?
    /// The page number or page count this field shows, in headers and footers (see `HeadersFooters`).
    public var pageField: PageField?

    init(parsing e: RawXML.Element, in doc: RawXML.Document) {
        kind = e.name
        xml = doc.slice(e.range)
        isDroppable = e.name == "w:proofErr"
        displayProperties = RunProperties(e.descendants(named: "w:rPr").first)
        image = ImageReference(drawing: e)
        newMedia = nil
        pageField = nil
        if let label = Self.objectLabel(e) {
            display = .object(label: label)
        } else {
            let text = Self.visibleText(e)
            display = text.isEmpty ? .invisible : .text(text)
        }
    }

    public var visibleText: String {
        switch display {
        case .text(let t): t
        case .object: "\u{FFFC}"
        case .invisible: ""
        }
    }

    public var isHyperlink: Bool { kind == "w:hyperlink" }

    /// What printing shows in place of an object's chip (backlog 27): the text in a text box, ending its line, nothing
    /// for a comment
    /// (Word doesn't print them), or nil to keep the chip.
    public var printedText: String? {
        guard case .object(let label) = display, image == nil else { return nil }
        switch label {
        case "Comment": return ""
        case "Text box":
            // The content is in the first w:txbxContent (Word writes a VML copy as a fallback).
            guard let root = (try? RawXML.Document(data: xml, part: kind))?.root,
                let content = root.descendants(named: "w:txbxContent").first
            else { return nil }
            return content.descendants(named: "w:p").map { p in
                p.childElements.map { Self.visibleText($0) }.joined()
            }.joined(separator: " ") + "\u{2028}"  // on a line of its own, not run into the text after it
        default: return nil
        }
    }

    /// A footnote or endnote reference: printing shows its number.
    public var noteReference: NoteKind? {
        guard case .object(let label) = display else { return nil }
        return label == "Footnote" ? .footnote : label == "Endnote" ? .endnote : nil
    }

    public enum NoteKind: Sendable { case footnote, endnote }

    static func objectLabel(_ e: RawXML.Element) -> String? {
        if !e.descendants(named: "w:txbxContent").isEmpty { return "Text box" }
        if !e.descendants(named: "w:drawing").isEmpty || !e.descendants(named: "w:pict").isEmpty { return "Image" }
        if !e.descendants(named: "w:object").isEmpty { return "Object" }
        if e.name.hasPrefix("m:") || !e.descendants(named: "m:oMath").isEmpty { return "Equation" }
        if !e.descendants(named: "w:footnoteReference").isEmpty { return "Footnote" }
        if !e.descendants(named: "w:endnoteReference").isEmpty { return "Endnote" }
        if !e.descendants(named: "w:commentReference").isEmpty { return "Comment" }
        if !e.descendants(named: "w:sym").isEmpty { return "Symbol" }
        if !e.descendants(named: "w:br").filter({ $0.attribute("w:type") == "page" }).isEmpty { return "Page break" }
        if !e.descendants(named: "w:br").filter({ $0.attribute("w:type") == "column" }).isEmpty {
            return "Column break"
        }
        return nil
    }

    /// Text a reader would see: `w:t` content, skipping deleted text, field codes and VML fallbacks.
    static func visibleText(_ e: RawXML.Element) -> String {
        var out = ""
        func walk(_ e: RawXML.Element) {
            switch e.name {
            case "w:t": out += e.text
            case "w:tab": out += "\t"
            case "w:del", "w:delText", "w:instrText", "mc:Fallback", "w:rPr", "w:pPr": return
            default: for c in e.childElements { walk(c) }
            }
        }
        walk(e)
        return out
    }
}

/// Verbatim body-level content.
public struct OpaqueBlock: Sendable {
    public var kind: String
    public var xml: Data
    public var leadingTrivia: Data
    public var visibleText: String

    init(parsing e: RawXML.Element, in doc: RawXML.Document, leadingTrivia: Data) {
        kind = e.name
        xml = doc.slice(e.range)
        self.leadingTrivia = leadingTrivia
        // Paragraph texts inside (table cells, content controls), one per line.
        visibleText = e.descendants(named: "w:p").map { p in
            p.childElements.map { OpaqueInline.visibleText($0) }.joined()
        }.joined(separator: "\n")
        if e.name == "w:tbl" {
            let rows = e.childElements(named: "w:tr").count
            let cols = e.firstChild(named: "w:tblGrid")?.childElements(named: "w:gridCol").count ?? 0
            summary = "Table, \(rows) × \(cols)"
        } else if e.name == "w:sdt" {
            summary = "Content control"
        } else if e.name == "w:sectPr" {
            summary = "Section"
        } else {
            summary = e.name
        }
    }

    /// Short description for the placeholder shown in the editor, e.g. "Table, 3 × 4".
    public var summary: String

    /// The final body `w:sectPr` (page setup); not shown in the editor.
    public var isSectionProperties: Bool { kind == "w:sectPr" }
}
