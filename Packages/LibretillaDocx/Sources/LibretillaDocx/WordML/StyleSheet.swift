import Foundation

/// `styles.xml` (plus theme fonts). Kept as its source bytes: edits splice single `w:style`
/// elements (adding a missing style, updating one from a selection) and leave the rest untouched.
public struct StyleSheet: Sendable {
    public struct Style: Sendable {
        public var id: String
        public var name: String
        /// `paragraph`, `character`, `table`, `numbering`.
        public var type: String
        public var basedOn: String?
        /// Style for the paragraph that follows when you press Return at the end of this one.
        public var next: String?
        /// Shown in Word's style gallery (`w:qFormat`).
        public var isQuickStyle: Bool
        public var run: RunProperties
        public var paragraph: ParagraphProperties
    }

    /// The `styles.xml` bytes this sheet was parsed from (nil if the document has no styles part).
    public private(set) var stylesXML: Data?
    private var themeXML: Data?

    public var defaultRun = RunProperties()
    public var defaultParagraph = ParagraphProperties()
    public var styles: [String: Style] = [:]
    public var defaultParagraphStyleId: String?
    /// Theme fonts (`a:majorFont` / `a:minorFont` latin typefaces).
    public var majorFont: String?
    public var minorFont: String?

    public init() {}

    public init(styles stylesXML: Data?, theme themeXML: Data?) throws {
        self.stylesXML = stylesXML
        self.themeXML = themeXML
        if let stylesXML {
            let root = try RawXML.Document(data: stylesXML, part: "styles").root
            if let defaults = root.firstChild(named: "w:docDefaults") {
                defaultRun = RunProperties(defaults.firstChild(named: "w:rPrDefault")?.firstChild(named: "w:rPr"))
                defaultParagraph = ParagraphProperties(
                    defaults.firstChild(named: "w:pPrDefault")?.firstChild(named: "w:pPr"))
            }
            for s in root.childElements(named: "w:style") {
                guard let id = s.attribute("w:styleId") else { continue }
                let type = s.attribute("w:type") ?? "paragraph"
                styles[id] = Style(
                    id: id, name: s.firstChild(named: "w:name")?.attribute("w:val") ?? id, type: type,
                    basedOn: s.firstChild(named: "w:basedOn")?.attribute("w:val"),
                    next: s.firstChild(named: "w:next")?.attribute("w:val"),
                    isQuickStyle: s.firstChild(named: "w:qFormat").map { RunProperties.toggle($0) } ?? false,
                    run: RunProperties(s.firstChild(named: "w:rPr")),
                    paragraph: ParagraphProperties(s.firstChild(named: "w:pPr")))
                if type == "paragraph", RunProperties.toggle(s, attribute: "w:default") {
                    defaultParagraphStyleId = id
                }
            }
        }
        if let themeXML {
            let root = try RawXML.Document(data: themeXML, part: "theme").root
            if let scheme = root.descendants(named: "a:fontScheme").first {
                majorFont = scheme.firstChild(named: "a:majorFont")?.firstChild(named: "a:latin")?.attribute(
                    "typeface")
                minorFont = scheme.firstChild(named: "a:minorFont")?.firstChild(named: "a:latin")?.attribute(
                    "typeface")
            }
        }
    }

    /// Style chain from the most basic style to `id` (cycle-safe).
    func chain(_ id: String?) -> [Style] {
        var out: [Style] = []
        var seen = Set<String>()
        var next = id
        while let current = next, !seen.contains(current), let style = styles[current] {
            seen.insert(current)
            out.insert(style, at: 0)
            next = style.basedOn
        }
        return out
    }

    /// Effective paragraph and run properties for a paragraph style (docDefaults → style chain).
    public func resolveParagraphStyle(_ id: String?) -> (ParagraphProperties, RunProperties) {
        var p = defaultParagraph
        var r = defaultRun
        for style in chain(id ?? defaultParagraphStyleId) {
            p = style.paragraph.over(p)
            r = style.run.over(r)
        }
        return (p, r)
    }

    /// Run properties contributed by a character style chain.
    public func resolveCharacterStyle(_ id: String?) -> RunProperties {
        chain(id).reduce(RunProperties()) { $1.run.over($0) }
    }

    /// Fully resolved run properties: docDefaults → paragraph style → character style → direct formatting.
    public func resolveRun(paragraphStyle: String?, direct: RunProperties) -> RunProperties {
        let (_, paragraphRun) = resolveParagraphStyle(paragraphStyle)
        return direct.over(resolveCharacterStyle(direct.styleId).over(paragraphRun))
    }

    /// Font family name for resolved run properties, applying theme fonts.
    public func fontFamily(for run: RunProperties) -> String? {
        if let theme = run.themeFont {
            return theme.hasPrefix("major") ? majorFont : minorFont
        }
        return run.font
    }

    /// Display name of a style, e.g. "heading 1".
    public func name(of id: String?) -> String? { id.flatMap { styles[$0]?.name } }

    /// The outline level of a paragraph style, for the outline sidebar and VoiceOver's heading rotor:
    /// 0 for Title, 1–9 for "heading 1"…"heading 9" (Word's canonical names, which localized Word keeps),
    /// nil for body text. A style based on a heading is a heading of that level, as in Word.
    public func outlineLevel(ofParagraphStyle id: String?) -> Int? {
        for style in chain(id ?? defaultParagraphStyleId).reversed() where style.type == "paragraph" {
            if let level = Self.outlineLevel(name: style.name) { return level }
        }
        return nil
    }

    static func outlineLevel(name: String) -> Int? {
        let n = name.lowercased()
        if n == "title" { return 0 }
        guard n.hasPrefix("heading "), let level = Int(n.dropFirst("heading ".count)), (1...9).contains(level)
        else { return nil }
        return level
    }
}

extension RunProperties {
    static func toggle(_ e: RawXML.Element, attribute: String) -> Bool {
        switch e.attribute(attribute) {
        case "1", "true", "on": true
        default: false
        }
    }
}

// MARK: - Finding and editing styles

extension StyleSheet {
    /// The id of the style with this built-in name (Word's canonical English names, e.g. `heading 1`,
    /// are the same in every language; the ids aren't). Falls back to an id match.
    public func styleId(named name: String, type: String = "paragraph") -> String? {
        let wanted = name.lowercased()
        if let s = styles.values.filter({ $0.type == type && $0.name.lowercased() == wanted }).min(by: { $0.id < $1.id }
        ) {
            return s.id
        }
        let compact = wanted.replacingOccurrences(of: " ", with: "")
        return styles.values.first { $0.type == type && $0.id.lowercased() == compact }?.id
    }

    /// Makes sure the style `id` of `template` exists here (with the styles it's based on), copying
    /// its definition. Returns the id to use, which is an existing style with the same name if any.
    public mutating func ensureStyle(_ id: String, from template: StyleSheet) -> String? {
        guard let style = template.styles[id] else { return styles[id] == nil ? nil : id }
        if let existing = styleId(named: style.name, type: style.type) { return existing }
        guard styles[id] == nil else { return id }
        if let basedOn = style.basedOn { _ = ensureStyle(basedOn, from: template) }
        if let next = style.next, next != id { _ = ensureStyle(next, from: template) }
        guard let element = template.styleElement(id) else { return nil }
        append(element)
        return styles[id] == nil ? nil : id
    }

    /// Bytes of one `w:style` element.
    func styleElement(_ id: String) -> Data? {
        guard let stylesXML, let doc = try? RawXML.Document(data: stylesXML) else { return nil }
        guard let e = doc.root.childElements(named: "w:style").first(where: { $0.attribute("w:styleId") == id })
        else { return nil }
        return doc.slice(e.range)
    }

    mutating func append(_ element: Data) {
        var bytes = Data([UInt8](stylesXML ?? Self.emptyPart))
        guard let root = try? RawXML.Document(data: bytes).root, !root.endTagRange.isEmpty else { return }
        bytes.insert(contentsOf: element, at: root.endTagRange.lowerBound)
        reload(bytes)
    }

    /// Rewrites the `w:pPr` and `w:rPr` of style `id` so the given fields say what `paragraph` and `run` say.
    public mutating func updateStyle(
        _ id: String, paragraph: ParagraphProperties, paragraphFields: Set<ParagraphProperties.Field>,
        run: RunProperties, runFields: Set<RunProperties.Field>
    ) {
        guard var bytes = stylesXML.map({ Data([UInt8]($0)) }), let doc = try? RawXML.Document(data: bytes),
            let e = doc.root.childElements(named: "w:style").first(where: { $0.attribute("w:styleId") == id })
        else { return }
        let order = [
            "w:name", "w:aliases", "w:basedOn", "w:next", "w:link", "w:autoRedefine", "w:hidden", "w:uiPriority",
            "w:semiHidden", "w:unhideWhenUsed", "w:qFormat", "w:locked", "w:personal", "w:personalCompose",
            "w:personalReply", "w:rsid", "w:pPr", "w:rPr", "w:tblPr", "w:trPr", "w:tcPr", "w:tblStylePr",
        ]
        var edits: [ElementPatch.Edit] = []
        let pPr = e.firstChild(named: "w:pPr").map { doc.slice($0.range) }
        let rPr = e.firstChild(named: "w:rPr").map { doc.slice($0.range) }
        let pFields = paragraphFields.subtracting([.style, .numbering])
        if !pFields.isEmpty {
            let new = paragraph.patching(pPr, fields: pFields)
            edits.append(new.map { .replace("w:pPr", xml: String(decoding: $0, as: UTF8.self)) } ?? .remove("w:pPr"))
        }
        let rFields = runFields.subtracting([.style])
        if !rFields.isEmpty {
            let new = run.patching(rPr, fields: rFields)
            edits.append(new.map { .replace("w:rPr", xml: String(decoding: $0, as: UTF8.self)) } ?? .remove("w:rPr"))
        }
        guard !edits.isEmpty,
            let patched = ElementPatch.apply(edits, to: doc.slice(e.range), wrapper: "w:style", order: order)
        else { return }
        bytes.replaceSubrange(e.range, with: patched)
        reload(bytes)
    }

    mutating func reload(_ bytes: Data) {
        if let sheet = try? StyleSheet(styles: bytes, theme: themeXML) { self = sheet }
    }

    static let emptyPart = Data(
        ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
            + "<w:styles xmlns:w=\"\(wordprocessingMLNamespace)\"></w:styles>").utf8)
}
