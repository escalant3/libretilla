import Foundation

/// Read-only view of `styles.xml` (plus theme fonts), used to display documents.
/// `styles.xml` itself is never rewritten in M1: it is copied through untouched.
public struct StyleSheet: Sendable {
    public struct Style: Sendable {
        public var id: String
        public var name: String
        /// `paragraph`, `character`, `table`, `numbering`.
        public var type: String
        public var basedOn: String?
        public var run: RunProperties
        public var paragraph: ParagraphProperties
    }

    public var defaultRun = RunProperties()
    public var defaultParagraph = ParagraphProperties()
    public var styles: [String: Style] = [:]
    public var defaultParagraphStyleId: String?
    /// Theme fonts (`a:majorFont` / `a:minorFont` latin typefaces).
    public var majorFont: String?
    public var minorFont: String?

    public init() {}

    public init(styles stylesXML: Data?, theme themeXML: Data?) throws {
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
}

extension RunProperties {
    static func toggle(_ e: RawXML.Element, attribute: String) -> Bool {
        switch e.attribute(attribute) {
        case "1", "true", "on": true
        default: false
        }
    }
}
