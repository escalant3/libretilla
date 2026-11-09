import AppKit

/// A run of the editor's text laid out with one page setup: a section of the document (ECMA-376 Part 1, §17.6).
public struct PageSection: Sendable, Equatable {
    /// The section's text, its last paragraph (the one holding its `w:sectPr`) included.
    public var range: NSRange
    public var setup: PageSetup

    public init(range: NSRange, setup: PageSetup) {
        self.range = range
        self.setup = setup
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
                    PageSection(range: NSRange(location: start, length: end - start), setup: PageSetup(sectPr: sectPr)))
            }
            start = end
        }
        if start < text.length || sections.isEmpty {
            sections.append(PageSection(range: NSRange(location: start, length: text.length - start), setup: last))
        }
        return sections
    }
}
