import AppKit

/// A run of the editor's text laid out with one page setup: a section of the document (ECMA-376 Part 1, §17.6).
public struct PageSection: Sendable, Equatable {
    /// The section's text, its last paragraph (the one holding its `w:sectPr`) included.
    public var range: NSRange
    public var setup: PageSetup
    /// Its own header and footer references (it inherits the others from the sections before it), and whether it
    /// has `w:titlePg`. Nil for the final section, whose headers and footers are the document's `headersFooters`.
    public var headerFooterReferences: [HeadersFooters.Key: String]?
    public var differentFirstPage = false

    public init(
        range: NSRange, setup: PageSetup, headerFooterReferences: [HeadersFooters.Key: String]? = nil,
        differentFirstPage: Bool = false
    ) {
        self.range = range
        self.setup = setup
        self.headerFooterReferences = headerFooterReferences
        self.differentFirstPage = differentFirstPage
    }
}

extension AttributedStringBridge {
    /// The document's sections in `text`: each ends with a paragraph whose properties hold a `w:sectPr`, and the
    /// last runs to the end with the final section's setup, `last`. A document without section breaks is one
    /// section. Empty sections are left out.
    public static func sections(in text: NSAttributedString, last: PageSetup) -> [PageSection] {
        var sections: [PageSection] = []
        var start = 0
        let all = NSRange(location: 0, length: text.length)
        var seen: Set<Int> = []
        text.enumerateAttribute(.libretillaParagraphFormat, in: all) { value, range, _ in
            guard let format = value as? ParagraphFormat, format.properties.hasSectionBreak, let xml = format.xml,
                let sectPr = (try? RawXML.Document(data: xml, part: "w:pPr"))?.root.firstChild(named: "w:sectPr")
            else { return }
            // The section ends with the paragraph (a format may be split into several attribute runs).
            let paragraph = (text.string as NSString).paragraphRange(
                for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            guard !seen.contains(paragraph.location) else { return }
            seen.insert(paragraph.location)
            let end = NSMaxRange(paragraph)
            if end > start {
                sections.append(
                    PageSection(
                        range: NSRange(location: start, length: end - start), setup: PageSetup(sectPr: sectPr),
                        headerFooterReferences: HeadersFooters.references(in: sectPr),
                        differentFirstPage: sectPr.firstChild(named: "w:titlePg").map(RunProperties.toggle) ?? false))
            }
            start = end
        }
        if start < text.length || sections.isEmpty {
            sections.append(PageSection(range: NSRange(location: start, length: text.length - start), setup: last))
        }
        return sections
    }
}

extension HeadersFooters {
    /// The headers and footers each of `sections` prints with, and whether its first page has its own (backlog 7):
    /// its own references and those it inherits from the sections before it. The final section uses these, as
    /// edited, and `differentFirstPage`.
    public func bySection(_ sections: [PageSection], differentFirstPage: Bool) -> [(
        headersFooters: HeadersFooters, differentFirstPage: Bool
    )] {
        var inherited: [Key: String] = [:]
        return sections.map { section in
            guard let own = section.headerFooterReferences else { return (self, differentFirstPage) }
            inherited.merge(own) { $1 }
            return (resolving(inherited), section.differentFirstPage)
        }
    }
}
