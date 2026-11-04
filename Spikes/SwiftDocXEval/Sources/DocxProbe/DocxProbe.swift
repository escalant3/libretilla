import Foundation
import ZIPFoundation

/// Library-independent inspection of a .docx package. This is the ground truth
/// the evaluation compares SwiftDocX against. It knows nothing about SwiftDocX.
public struct DocxProbe: Sendable {
    /// Every zip entry, by name.
    public let parts: [String: Data]
    /// Element-occurrence counts in `word/document.xml`, keyed by `Feature`.
    public let features: [Feature: Int]
    /// `w:pStyle` values used in the body, with counts.
    public let paragraphStyles: [String: Int]
    /// Visible body text: `w:t` content, a newline after each `w:p`. Excludes `w:delText`.
    public let text: String
    /// Parts whose XML failed to parse, with the error.
    public let malformedParts: [String: String]
    /// Structural problems: parts missing a content type, dangling relationships, …
    public let packageProblems: [String]

    public var words: Int { Self.wordCount(text) }

    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    public init(url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: false) { data.append($0) }
            parts[entry.path] = data
        }
        self.parts = parts

        var malformed: [String: String] = [:]
        for (name, data) in parts where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: data)
            if !parser.parse() {
                malformed[name] = parser.parserError?.localizedDescription ?? "unknown"
            }
        }
        self.malformedParts = malformed

        guard let document = parts["word/document.xml"] else {
            self.features = [:]
            self.paragraphStyles = [:]
            self.text = ""
            self.packageProblems = ["missing word/document.xml"]
            return
        }
        let scan = BodyScanner.scan(document)
        self.features = scan.features
        self.paragraphStyles = scan.styles
        self.text = scan.text
        self.packageProblems = PackageChecker.problems(parts: parts)
    }

    /// Feature counts for any XML part (e.g. headers, footers, footnotes).
    public func features(inPart name: String) -> [Feature: Int] {
        guard let data = parts[name] else { return [:] }
        return BodyScanner.scan(data).features
    }

    /// Names of the package's parts, sorted.
    public var partNames: [String] { parts.keys.sorted() }
}

/// What the evaluation counts in `word/document.xml`.
public enum Feature: String, CaseIterable, Sendable, Comparable {
    case paragraph = "w:p"
    case run = "w:r"
    case headingParagraph = "Heading pStyle"
    case styledParagraph = "w:pStyle"
    case listParagraph = "w:numPr"
    case alignment = "w:jc"
    case spacing = "w:spacing"
    case indentation = "w:ind"
    case bold = "w:b"
    case italic = "w:i"
    case underline = "w:u"
    case strike = "w:strike"
    case color = "w:color"
    case highlight = "w:highlight"
    case fontSize = "w:sz"
    case fonts = "w:rFonts"
    case vertAlign = "w:vertAlign"
    case language = "w:lang"
    case table = "w:tbl"
    case tableRow = "w:tr"
    case tableCell = "w:tc"
    case tableHeader = "w:tblHeader"
    case gridSpan = "w:gridSpan"
    case vMerge = "w:vMerge"
    case cellShading = "w:shd"
    case hyperlink = "w:hyperlink"
    case bookmark = "w:bookmarkStart"
    case drawing = "w:drawing"
    case imageBlip = "a:blip"
    case pageBreak = "w:br page"
    case sectionProps = "w:sectPr"
    case headerReference = "w:headerReference"
    case footerReference = "w:footerReference"
    case pageSize = "w:pgSz"
    case columns = "w:cols num>1"
    case footnoteReference = "w:footnoteReference"
    case commentReference = "w:commentReference"
    case insertion = "w:ins"
    case deletion = "w:del"
    case complexField = "w:fldChar begin"
    case simpleField = "w:fldSimple"
    case contentControl = "w:sdt"
    case textBox = "w:txbxContent"
    case alternateContent = "mc:AlternateContent"
    case math = "m:oMath"

    public static func < (a: Feature, b: Feature) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

private final class BodyScanner: NSObject, XMLParserDelegate {
    var features: [Feature: Int] = [:]
    var styles: [String: Int] = [:]
    var text = ""
    private var inText = false
    private var stack: [String] = []

    static func scan(_ data: Data) -> BodyScanner {
        let scanner = BodyScanner()
        let parser = XMLParser(data: data)
        parser.delegate = scanner
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return scanner
    }

    private func bump(_ f: Feature) { features[f, default: 0] += 1 }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
        let parent = stack.last
        stack.append(name)
        let inRPr = parent == "w:rPr"
        switch name {
        case "w:p": bump(.paragraph)
        case "w:r": bump(.run)
        case "w:pStyle":
            bump(.styledParagraph)
            let v = attributes["w:val"] ?? ""
            styles[v, default: 0] += 1
            if v.lowercased().hasPrefix("heading") || v == "Title" || v == "Subtitle" { bump(.headingParagraph) }
        case "w:numPr": bump(.listParagraph)
        case "w:jc" where parent == "w:pPr": bump(.alignment)
        case "w:spacing" where parent == "w:pPr": bump(.spacing)
        case "w:ind" where parent == "w:pPr": bump(.indentation)
        case "w:b" where inRPr: bump(.bold)
        case "w:i" where inRPr: bump(.italic)
        case "w:u" where inRPr: bump(.underline)
        case "w:strike" where inRPr: bump(.strike)
        case "w:color" where inRPr: bump(.color)
        case "w:highlight" where inRPr: bump(.highlight)
        case "w:sz" where inRPr: bump(.fontSize)
        case "w:rFonts" where inRPr: bump(.fonts)
        case "w:vertAlign" where inRPr: bump(.vertAlign)
        case "w:lang" where inRPr: bump(.language)
        case "w:tbl": bump(.table)
        case "w:tr": bump(.tableRow)
        case "w:tc": bump(.tableCell)
        case "w:tblHeader": bump(.tableHeader)
        case "w:gridSpan": bump(.gridSpan)
        case "w:vMerge": bump(.vMerge)
        case "w:shd" where parent == "w:tcPr": bump(.cellShading)
        case "w:hyperlink": bump(.hyperlink)
        case "w:bookmarkStart": bump(.bookmark)
        case "w:drawing": bump(.drawing)
        case "a:blip": bump(.imageBlip)
        case "w:br" where attributes["w:type"] == "page": bump(.pageBreak)
        case "w:sectPr": bump(.sectionProps)
        case "w:headerReference": bump(.headerReference)
        case "w:footerReference": bump(.footerReference)
        case "w:pgSz": bump(.pageSize)
        case "w:cols" where (Int(attributes["w:num"] ?? "1") ?? 1) > 1: bump(.columns)
        case "w:footnoteReference": bump(.footnoteReference)
        case "w:commentReference": bump(.commentReference)
        case "w:ins": bump(.insertion)
        case "w:del": bump(.deletion)
        case "w:fldChar" where attributes["w:fldCharType"] == "begin": bump(.complexField)
        case "w:fldSimple": bump(.simpleField)
        case "w:sdt": bump(.contentControl)
        case "w:txbxContent": bump(.textBox)
        case "mc:AlternateContent": bump(.alternateContent)
        case "m:oMath": bump(.math)
        case "w:t": inText = !stack.contains("mc:Fallback")  // don't double-count VML fallback text
        case "w:tab" where parent == "w:r": text += "\t"
        default: break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        stack.removeLast()
        if name == "w:t" { inText = false }
        if name == "w:p" && !stack.contains("mc:Fallback") { text += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }
}

/// Minimal OPC sanity checks (what makes Word show a "repair" prompt most often).
enum PackageChecker {
    static func problems(parts: [String: Data]) -> [String] {
        var problems: [String] = []
        guard let ctData = parts["[Content_Types].xml"] else { return ["missing [Content_Types].xml"] }
        let ct = ContentTypes.parse(ctData)
        for name in parts.keys where name != "[Content_Types].xml" {
            // Not NSString.pathExtension: it returns "" for "_rels/.rels".
            let last = name.split(separator: "/").last.map(String.init) ?? name
            let ext = last.split(separator: ".").last.map { String($0).lowercased() } ?? ""
            if ct.overrides["/" + name] == nil && ct.defaults[ext] == nil {
                problems.append("no content type for \(name)")
            }
        }
        for override in ct.overrides.keys where parts[String(override.dropFirst())] == nil {
            problems.append("content-type override for missing part \(override)")
        }
        for (relsName, data) in parts where relsName.hasSuffix(".rels") {
            // _rels/.rels → base "", word/_rels/document.xml.rels → base "word/"
            let dir = (relsName as NSString).deletingLastPathComponent  // e.g. word/_rels
            let base = (dir as NSString).deletingLastPathComponent  // e.g. word
            for rel in Relationships.parse(data) where rel.mode != "External" {
                let target = rel.target.hasPrefix("/")
                    ? String(rel.target.dropFirst())
                    : resolve(rel.target, against: base)
                if parts[target] == nil { problems.append("\(relsName): dangling \(rel.id) → \(rel.target)") }
            }
        }
        return problems.sorted()
    }

    /// Joins a relative OPC target onto a base folder, collapsing `.` and `..`
    /// (NSString.standardizingPath leaves `..` in relative paths).
    static func resolve(_ target: String, against base: String) -> String {
        var out: [Substring] = base.split(separator: "/")
        for c in target.split(separator: "/") {
            switch c {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(c)
            }
        }
        return out.joined(separator: "/")
    }
}

private final class ContentTypes: NSObject, XMLParserDelegate {
    var defaults: [String: String] = [:]
    var overrides: [String: String] = [:]
    static func parse(_ data: Data) -> ContentTypes {
        let c = ContentTypes()
        let p = XMLParser(data: data)
        p.delegate = c
        _ = p.parse()
        return c
    }
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
        if name == "Default", let e = attributes["Extension"] { defaults[e.lowercased()] = attributes["ContentType"] }
        if name == "Override", let n = attributes["PartName"] { overrides[n] = attributes["ContentType"] }
    }
}

struct Relationship { var id: String, target: String, mode: String? }

private final class Relationships: NSObject, XMLParserDelegate {
    var rels: [Relationship] = []
    static func parse(_ data: Data) -> [Relationship] {
        let r = Relationships()
        let p = XMLParser(data: data)
        p.delegate = r
        _ = p.parse()
        return r.rels
    }
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
        if name == "Relationship" {
            rels.append(
                Relationship(
                    id: attributes["Id"] ?? "?", target: attributes["Target"] ?? "", mode: attributes["TargetMode"]))
        }
    }
}

/// Part-level comparison of two packages.
public struct PackageDiff: Sendable {
    public let identical: [String]
    public let changed: [String]
    public let dropped: [String]
    public let added: [String]

    public init(from a: DocxProbe, to b: DocxProbe) {
        let an = Set(a.parts.keys), bn = Set(b.parts.keys)
        identical = an.intersection(bn).filter { a.parts[$0] == b.parts[$0] }.sorted()
        changed = an.intersection(bn).filter { a.parts[$0] != b.parts[$0] }.sorted()
        dropped = an.subtracting(bn).sorted()
        added = bn.subtracting(an).sorted()
    }
}
