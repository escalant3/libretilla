import AppKit

/// A field in a header or footer that shows the page number (`PAGE`) or the number of pages (`NUMPAGES`,
/// and `SECTIONPAGES`, which is the same while Libretilla treats the document as one section). Printing
/// replaces the result Word stored with the real number.
public enum PageField: String, Sendable, Equatable {
    case page
    case pageCount

    init?(instruction: String) {
        switch instruction.split(whereSeparator: \.isWhitespace).first?.uppercased() {
        case "PAGE": self = .page
        case "NUMPAGES", "SECTIONPAGES": self = .pageCount
        default: return nil
        }
    }

    var instruction: String { self == .page ? "PAGE" : "NUMPAGES" }

    /// The chip's label in the editor (English; the app translates it through `localizeLabel`).
    public var label: String { self == .page ? "Page number" : "Page count" }
}

/// The headers and footers the document's last section uses (ECMA-376 Part 1, §17.10), each parsed like the
/// body so it round-trips losslessly and edits rewrite only the paragraphs that changed.
///
/// The editor edits the last section's headers and footers, as it does its page setup. Printing gives each section
/// its own (`resolving`). A section without a reference of some type inherits it from the sections before it, as in
/// Word.
public struct HeadersFooters: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case header
        case footer

        var referenceName: String { self == .header ? "w:headerReference" : "w:footerReference" }
        var rootName: String { self == .header ? "w:hdr" : "w:ftr" }
        var relationshipType: String {
            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(rawValue)"
        }
        var contentType: String { "application/vnd.openxmlformats-officedocument.wordprocessingml.\(rawValue)+xml" }
        /// The built-in paragraph style Word gives header and footer text.
        public var styleName: String { rawValue }
    }

    /// Which pages a header or footer is for (`w:type` of its reference).
    public enum Slot: String, Sendable, CaseIterable {
        case `default`
        /// The first page, when the section has `w:titlePg`.
        case first
        /// Even pages, when settings have `w:evenAndOddHeaders`.
        case even
    }

    public struct Key: Hashable, Sendable {
        public var kind: Kind
        public var slot: Slot
        public init(_ kind: Kind, _ slot: Slot) {
            self.kind = kind
            self.slot = slot
        }
    }

    /// One header or footer part.
    public struct Story: Sendable {
        /// The part, e.g. `word/header1.xml`; nil for one made in Libretilla (each save creates its part).
        public var partName: String?
        public var body: DocumentBody
        /// The part's own external link targets and images, by relationship id.
        public var hyperlinkTargets: [String: String] = [:]
        public var images: [String: Data] = [:]

        /// No text and nothing else visible (a new story the user left empty).
        public var isEmpty: Bool {
            body.blocks.allSatisfy {
                switch $0 {
                case .paragraph(let p): p.inlines.allSatisfy { $0.visibleText.isEmpty }
                case .opaque(let o): o.isSectionProperties || o.visibleText.isEmpty && o.kind != "w:tbl"
                }
            }
        }

        /// The story as printed on page `page` of `pages`: page fields show the real numbers, and the content of
        /// block content controls (Word's Page Number gallery wraps page numbers in one) shows as text.
        public func printableBody(page: Int, pages: Int) -> DocumentBody {
            func substituted(_ p: Paragraph) -> Paragraph {
                var p = p
                for (i, inline) in p.inlines.enumerated() {
                    guard case .opaque(var o) = inline, let field = o.pageField else { continue }
                    o.display = .text(String(field == .page ? page : pages))
                    p.inlines[i] = .opaque(o)
                }
                return p
            }
            var out = body
            out.blocks = body.blocks.flatMap { block -> [Block] in
                switch block {
                case .paragraph(let p): [.paragraph(substituted(p))]
                case .opaque(let o) where o.kind == "w:sdt":
                    HeadersFooters.contentBlocks(ofContentControl: o).map {
                        if case .paragraph(let p) = $0 { .paragraph(substituted(p)) } else { $0 }
                    }
                case .opaque: [block]
                }
            }
            return out
        }
    }

    public var stories: [Key: Story] = [:]
    /// References whose part exists but couldn't be read. They're kept as they are, and can't be edited.
    public var unreadable: Set<Key> = []
    /// `w:evenAndOddHeaders` in the settings: even pages use the even header and footer.
    public var evenAndOddPages = false
    /// Every section's header and footer parts as read, by relationship id, for printing (`resolving`).
    var partsById: [String: Story] = [:]
    /// The relationship id behind each of `stories` read from the file.
    var references: [Key: String] = [:]

    public init() {}

    /// The header or footer printed on page `page` (from 1), or nil for none. `isFirstPage` is whether it's the
    /// first page of its section (by default, of the document).
    public func story(_ kind: Kind, page: Int, differentFirstPage: Bool, isFirstPage: Bool? = nil) -> Story? {
        stories[Key(kind, slot(page: page, differentFirstPage: differentFirstPage, isFirstPage: isFirstPage))]
    }

    public func slot(page: Int, differentFirstPage: Bool, isFirstPage: Bool? = nil) -> Slot {
        if isFirstPage ?? (page == 1), differentFirstPage { return .first }
        return evenAndOddPages && page % 2 == 0 ? .even : .default
    }

    /// The headers and footers of a section with these references (its own and those it inherits, `PageSection`):
    /// a part the last section also uses is printed as edited, any other as read.
    public func resolving(_ sectionReferences: [Key: String]) -> HeadersFooters {
        var out = HeadersFooters()
        out.evenAndOddPages = evenAndOddPages
        for (key, id) in sectionReferences {
            if let edited = references.first(where: { $0.value == id }).flatMap({ stories[$0.key] }) {
                out.stories[key] = edited
            } else if let story = partsById[id] {
                out.stories[key] = story
            }
        }
        return out
    }

    /// The header and footer references in a `w:sectPr`, by kind and slot.
    static func references(in sectPr: RawXML.Element) -> [Key: String] {
        var refs: [Key: String] = [:]
        for e in sectPr.childElements {
            let kind: Kind
            switch e.name {
            case "w:headerReference": kind = .header
            case "w:footerReference": kind = .footer
            default: continue
            }
            guard let slot = Slot(rawValue: e.attribute("w:type") ?? "default"),
                let id = e.attributes.first(where: { $0.name.hasSuffix(":id") })?.value
            else { continue }
            refs[Key(kind, slot)] = id
        }
        return refs
    }

    /// A new header or footer: one empty paragraph in `styleId` (Word's "header" or "footer" style).
    public static func newStory(_ kind: Kind, styleId: String?) -> Story {
        let pPr = styleId.map { "<w:pPr><w:pStyle w:val=\"\(RawXML.escapeAttribute($0))\"/></w:pPr>" } ?? ""
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
            + "<\(kind.rootName) xmlns:w=\"\(wordprocessingMLNamespace)\" "
            + "xmlns:r=\"\(OOXMLCodec.relationshipsNamespace)\"><w:p>\(pPr)</w:p></\(kind.rootName)>"
        // Parsing Libretilla's own literal can't fail.
        let body = try! DocumentBody(data: Data(xml.utf8), part: "\(kind.rawValue).xml")
        return Story(partName: nil, body: body)
    }

    // MARK: - Fields

    /// `p` with each `PAGE` / `NUMPAGES` field, simple (`w:fldSimple`) or complex (`w:fldChar` begin … end), as one
    /// opaque inline holding all of its markup. The editor shows it as a chip and printing as the real number;
    /// it's written back with the same markup. Only an unedited paragraph's bytes are untouched, as for the body.
    static func collapsingPageFields(_ p: Paragraph) -> Paragraph {
        var out: [Inline] = []
        var i = 0
        let inlines = p.inlines
        while i < inlines.count {
            if case .opaque(var o) = inlines[i] {
                if o.kind == "w:fldSimple", let instr = Self.element(o)?.attribute("w:instr"),
                    let field = PageField(instruction: instr)
                {
                    o.pageField = field
                    o.display = .object(label: field.label)
                    out.append(.opaque(o))
                    i += 1
                    continue
                }
                if Self.fieldChars(inlines[i]).first == "begin",
                    let (end, field, props) = Self.complexField(inlines, at: i)
                {
                    o.xml = inlines[i...end].reduce(into: Data()) { $0.append($1.serialized()) }
                    o.pageField = field
                    o.display = .object(label: field.label)
                    if let props { o.displayProperties = props }
                    out.append(.opaque(o))
                    i = end + 1
                    continue
                }
            }
            out.append(inlines[i])
            i += 1
        }
        var result = p
        result.inlines = out
        return result
    }

    /// The end of the complex field that begins at `start`, if it's a page field and ends in this paragraph, with
    /// the formatting of its result.
    private static func complexField(_ inlines: [Inline], at start: Int) -> (Int, PageField, RunProperties?)? {
        var depth = 0
        var separated = false
        var instruction = ""
        var resultProperties: RunProperties?
        for j in start..<inlines.count {
            let inline = inlines[j]
            if depth == 1 && !separated, case .opaque(let o) = inline, let e = Self.element(o) {
                instruction += e.descendants(named: "w:instrText").map(\.text).joined()
            }
            if depth == 1 && separated && resultProperties == nil, case .run(let r) = inline {
                resultProperties = r.properties
            }
            for type in Self.fieldChars(inline) {
                switch type {
                case "begin": depth += 1
                case "separate" where depth == 1: separated = true
                case "end":
                    depth -= 1
                    if depth == 0 {
                        guard let field = PageField(instruction: instruction) else { return nil }
                        return (j, field, resultProperties)
                    }
                default: break
                }
            }
        }
        return nil
    }

    private static func fieldChars(_ inline: Inline) -> [String] {
        guard case .opaque(let o) = inline, o.kind == "w:r", let e = Self.element(o) else { return [] }
        return e.descendants(named: "w:fldChar").compactMap { $0.attribute("w:fldCharType") }
    }

    private static func element(_ o: OpaqueInline) -> RawXML.Element? {
        (try? RawXML.Document(data: o.xml, part: o.kind))?.root
    }

    /// The paragraphs and other blocks inside a block content control's `w:sdtContent` (display only).
    static func contentBlocks(ofContentControl o: OpaqueBlock) -> [Block] {
        guard let doc = try? RawXML.Document(data: o.xml, part: "w:sdt"),
            let content = doc.root.firstChild(named: "w:sdtContent")
        else { return [.opaque(o)] }
        return content.childElements.map { e in
            e.name == "w:p"
                ? .paragraph(collapsingPageFields(Paragraph(parsing: e, in: doc, leadingTrivia: Data())))
                : .opaque(OpaqueBlock(parsing: e, in: doc, leadingTrivia: Data()))
        }
    }
}

// MARK: - Reading and writing

extension OOXMLCodec {
    static let settingsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"

    static func readHeadersFooters(
        package: OPCPackage, main: String, rels: [Relationship], body: DocumentBody
    ) -> HeadersFooters {
        var result = HeadersFooters()
        if let settings = rels.first(where: { $0.type == settingsType })?.resolvedPartName.flatMap({ package[$0] }),
            let root = try? RawXML.Document(data: settings, part: "settings").root
        {
            result.evenAndOddPages = root.firstChild(named: "w:evenAndOddHeaders").map(RunProperties.toggle) ?? false
        }
        /// The story in the part with relationship id `id`: nil if there's none, `.failure` if it can't be read.
        func story(_ id: String) -> Result<HeadersFooters.Story, CocoaError>? {
            guard let rel = rels.first(where: { $0.id == id && !$0.isExternal }), let name = rel.resolvedPartName,
                let data = package[name]
            else { return nil }
            guard var story = try? DocumentBody(data: data, part: name), story.readOnlyReason == nil else {
                return .failure(CocoaError(.fileReadCorruptFile))
            }
            story.blocks = story.blocks.map {
                if case .paragraph(let p) = $0 { .paragraph(HeadersFooters.collapsingPageFields(p)) } else { $0 }
            }
            var s = HeadersFooters.Story(partName: name, body: story)
            let storyRels = (try? package.relationships(of: name)) ?? []
            for r in storyRels {
                if r.type == hyperlinkType && r.isExternal { s.hyperlinkTargets[r.id] = r.target }
                if r.type == imageType && !r.isExternal, let n = r.resolvedPartName, let d = package[n] {
                    s.images[r.id] = d
                }
            }
            return .success(s)
        }
        for (key, id) in body.headerFooterReferences {
            switch story(id) {
            case .success(let s):
                result.stories[key] = s
                result.references[key] = id
            case .failure: result.unreadable.insert(key)
            case nil: break
            }
        }
        for id in Set(body.allSectionProperties.flatMap { HeadersFooters.references(in: $0).values }) {
            if case .success(let s) = story(id) { result.partsById[id] = s }
        }
        return result
    }

    /// Writes edited stories into their parts, and creates parts and references for new ones.
    static func writeHeadersFooters(
        _ hf: HeadersFooters, body: inout DocumentBody, package: inout OPCPackage, main: String
    ) throws {
        var newReferences: [(HeadersFooters.Key, String)] = []
        for kind in HeadersFooters.Kind.allCases {
            for slot in HeadersFooters.Slot.allCases {
                let key = HeadersFooters.Key(kind, slot)
                guard var story = hf.stories[key], !hf.unreadable.contains(key) else { continue }
                let name: String
                if let existing = story.partName {
                    name = existing
                } else {
                    if story.isEmpty { continue }
                    name = package.numberedPartName(near: main, stem: kind.rawValue, ext: "xml")
                    let id = try package.addRelatedPart(
                        of: main, type: kind.relationshipType, contentType: kind.contentType, name: name, data: Data())
                    newReferences.append((key, id))
                }
                try resolveNewHyperlinks(in: &story.body, package: &package, part: name)
                try resolveNewPictures(in: &story.body, package: &package, part: name)
                package.setPart(name, data: story.body.serialized())
            }
        }
        if !newReferences.isEmpty { body.addHeaderFooterReferences(newReferences) }
    }
}

extension DocumentBody {
    /// Every section's `w:sectPr`, in order: those in paragraph properties, then the final one.
    var allSectionProperties: [RawXML.Element] {
        blocks.compactMap { block in
            switch block {
            case .paragraph(let p) where p.propertiesXMLWithoutSectionBreak != nil:
                p.propertiesXML.flatMap { try? RawXML.Document(data: $0, part: "w:pPr") }?.root
                    .firstChild(named: "w:sectPr")
            case .opaque(let o) where o.isSectionProperties:
                (try? RawXML.Document(data: o.xml, part: "w:sectPr"))?.root
            default: nil
            }
        }
    }

    /// The relationship id of each header and footer the last section uses, its own or inherited.
    var headerFooterReferences: [(HeadersFooters.Key, String)] {
        var refs: [HeadersFooters.Key: String] = [:]
        for sect in allSectionProperties {
            refs.merge(HeadersFooters.references(in: sect)) { $1 }
        }
        return HeadersFooters.Kind.allCases.flatMap { kind in
            HeadersFooters.Slot.allCases.compactMap { slot in
                refs[HeadersFooters.Key(kind, slot)].map { (HeadersFooters.Key(kind, slot), $0) }
            }
        }
    }

    /// `w:titlePg` in the final section: the first page has its own header and footer.
    public var differentFirstPage: Bool {
        get {
            guard let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i],
                let root = try? RawXML.Document(data: o.xml, part: "w:sectPr").root
            else { return false }
            return root.firstChild(named: "w:titlePg").map(RunProperties.toggle) ?? false
        }
        set {
            guard newValue != differentFirstPage else { return }
            patchSectionProperties([newValue ? .replace("w:titlePg", xml: "<w:titlePg/>") : .remove("w:titlePg")])
        }
    }

    /// Adds (or repoints) the final section's references, keeping the others' bytes.
    mutating func addHeaderFooterReferences(_ references: [(HeadersFooters.Key, String)]) {
        let root: RawXML.Element? = {
            guard let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i] else { return nil }
            return (try? RawXML.Document(data: o.xml, part: "w:sectPr"))?.root
        }()
        var sectXML = Data()
        // Zero-based, like the parser's ranges.
        if let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i] { sectXML = Data([UInt8](o.xml)) }
        // Declare the relationships prefix on the element if the document root doesn't.
        let declaresR = String(decoding: prefix, as: UTF8.self).contains(
            "xmlns:r=\"\(OOXMLCodec.relationshipsNamespace)\"")
        let ns = declaresR ? "" : " xmlns:r=\"\(OOXMLCodec.relationshipsNamespace)\""
        var edits: [ElementPatch.Edit] = []
        for kind in HeadersFooters.Kind.allCases {
            let new = references.filter { $0.0.kind == kind }
            guard !new.isEmpty else { continue }
            let replaced = Set(new.map(\.0.slot.rawValue))
            let kept = (root?.childElements(named: kind.referenceName) ?? []).filter {
                !replaced.contains($0.attribute("w:type") ?? "default")
            }.map { String(decoding: sectXML[$0.range], as: UTF8.self) }
            let added = new.map { key, id in
                "<\(kind.referenceName) w:type=\"\(key.slot.rawValue)\" r:id=\"\(RawXML.escapeAttribute(id))\"\(ns)/>"
            }
            edits.append(.replace(kind.referenceName, xml: (kept + added).joined()))
        }
        patchSectionProperties(edits)
    }

    /// Applies `edits` to the final `w:sectPr`, creating one with the fallback page setup if there's none.
    private mutating func patchSectionProperties(_ edits: [ElementPatch.Edit]) {
        var existing: OpaqueBlock?
        if let i = sectionPropertiesIndex, case .opaque(let o) = blocks[i] { existing = o }
        let start =
            existing?.xml
            ?? {
                let s = PageSetup.fallback
                return Data(
                    ("<w:sectPr><w:pgSz w:w=\"\(s.width)\" w:h=\"\(s.height)\"/><w:pgMar w:top=\"\(s.top)\" "
                        + "w:right=\"\(s.right)\" w:bottom=\"\(s.bottom)\" w:left=\"\(s.left)\" w:header=\"720\" "
                        + "w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>").utf8)
            }()
        guard
            let xml = ElementPatch.apply(
                edits, to: start, wrapper: "w:sectPr", order: ElementPatch.sectionPropertiesOrder),
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

extension AttributedStringBridge {
    /// This bridge for a header or footer: same styles and lists, the story's own links and images.
    public func forStory(_ story: HeadersFooters.Story) -> AttributedStringBridge {
        AttributedStringBridge(
            styles: styles, numbering: numbering, hyperlinkTargets: story.hyperlinkTargets, images: story.images,
            textWidth: textWidth)
    }
}

extension OpaqueInline {
    /// A new `PAGE` or `NUMPAGES` field (`w:fldSimple`), its result run formatted with `runPropertiesXML`.
    public static func newPageField(_ field: PageField, runPropertiesXML: Data?) -> OpaqueInline {
        let rPr = runPropertiesXML.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let xml = "<w:fldSimple w:instr=\" \(field.instruction) \"><w:r>\(rPr)<w:t>1</w:t></w:r></w:fldSimple>"
        // Libretilla's own markup, with run properties that were parsed from the document: parses.
        let doc = try! RawXML.Document(data: Data(xml.utf8), part: "w:fldSimple")
        var o = OpaqueInline(parsing: doc.root, in: doc)
        o.pageField = field
        o.display = .object(label: field.label)
        return o
    }
}

extension AttributedStringBridge {
    /// A page number or page count field to insert at the caret of a header or footer, shown as a chip and
    /// formatted as the caret would type.
    public func pageField(_ field: PageField, typingAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attrs = typingAttributes
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        let run = attrs[.libretillaRun] as? RunFormat
        attrs[.libretillaRun] = nil
        attrs[.libretillaOpaque] = OpaqueInlineBox(.newPageField(field, runPropertiesXML: run?.xml))
        attrs[.attachment] = Self.placeholderAttachment(field.label, font: attrs[.font] as? NSFont)
        return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
    }
}
