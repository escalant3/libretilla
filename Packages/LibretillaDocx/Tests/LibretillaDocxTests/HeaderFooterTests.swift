import AppKit
import Foundation
import Testing

@testable import LibretillaDocx

@MainActor
@Suite struct HeaderFooterTests {
    let codec = OOXMLCodec()
    typealias Key = HeadersFooters.Key

    func text(_ story: HeadersFooters.Story?) -> String? { story?.body.plainText }

    func printed(_ story: HeadersFooters.Story?, page: Int, of pages: Int) -> String? {
        story?.printableBody(page: page, pages: pages).plainText
    }

    func part(_ doc: DocxDocument, _ name: String) -> String {
        String(decoding: doc.package[name] ?? Data(), as: UTF8.self)
    }

    /// Edits a story through the bridge, as the Header and Footer sheet does.
    func edit(
        _ story: HeadersFooters.Story, in doc: DocxDocument, _ change: (NSMutableAttributedString) -> Void
    ) -> HeadersFooters.Story {
        let bridge = AttributedStringBridge(doc).forStory(story)
        let text = NSMutableAttributedString(attributedString: bridge.attributedString(for: story.body))
        change(text)
        var out = story
        out.body = bridge.body(from: text, base: story.body).body
        return out
    }

    func fields(_ p: Paragraph) -> [PageField] {
        p.inlines.compactMap { inline -> PageField? in
            if case .opaque(let o) = inline { return o.pageField }
            return nil
        }
    }

    func replace(_ old: String, with new: String) -> (NSMutableAttributedString) -> Void {
        { text in
            let r = (text.string as NSString).range(of: old)
            text.replaceCharacters(in: r, with: new)
        }
    }

    @Test func readsEverySlotOfTheLastSection() throws {
        let doc = try codec.read(try Corpus.data("14-headers-footers.docx"))
        let hf = doc.headersFooters
        #expect(
            Set(hf.stories.keys) == [
                Key(.header, .first), Key(.header, .default), Key(.header, .even), Key(.footer, .default),
                Key(.footer, .even),
            ])
        #expect(hf.evenAndOddPages)
        #expect(doc.body.differentFirstPage)
        #expect(text(hf.story(.header, page: 1, differentFirstPage: true)) == "Cover page header")
        #expect(hf.story(.footer, page: 1, differentFirstPage: true) == nil)
        #expect(text(hf.story(.header, page: 2, differentFirstPage: true)) == "Even page header")
        #expect(text(hf.story(.header, page: 3, differentFirstPage: true)) == "Odd page header")
        #expect(text(hf.story(.header, page: 1, differentFirstPage: false)) == "Odd page header")
        #expect(hf.stories[Key(.header, .default)]?.partName == "word/header2.xml")
    }

    @Test func documentWithoutHeadersHasNone() throws {
        let doc = try codec.read(try Corpus.data("01-plain.docx"))
        #expect(doc.headersFooters.stories.isEmpty)
        #expect(!doc.body.differentFirstPage)
        #expect(!doc.headersFooters.evenAndOddPages)
    }

    @Test func pageFieldsBecomeOneInlineEach() throws {
        let doc = try codec.read(try Corpus.data("14-headers-footers.docx"))
        guard case .paragraph(let p) = try #require(doc.headersFooters.stories[Key(.footer, .default)]).body.blocks[0]
        else { Issue.record("no paragraph"); return }
        #expect(fields(p) == [.page, .pageCount])
        // Complex (fldChar) in fixture 07 too.
        let doc07 = try codec.read(try Corpus.data("07-header-footer.docx"))
        guard case .paragraph(let q) = try #require(doc07.headersFooters.stories[Key(.footer, .default)]).body.blocks[0]
        else { Issue.record("no paragraph"); return }
        #expect(fields(q) == [.page])
    }

    @Test func printingShowsTheRealNumbers() throws {
        let hf = try codec.read(try Corpus.data("14-headers-footers.docx")).headersFooters
        #expect(printed(hf.story(.footer, page: 3, differentFirstPage: true), page: 3, of: 5) == "Page 3 of 5")
        // Inside Word's Page Number content control.
        #expect(printed(hf.story(.footer, page: 4, differentFirstPage: true), page: 4, of: 5) == "Even page 4")
        let hf07 = try codec.read(try Corpus.data("07-header-footer.docx")).headersFooters
        #expect(printed(hf07.stories[Key(.footer, .default)], page: 2, of: 4) == "Page 2")
    }

    @Test func editingOneStoryRewritesOnlyItsParagraph() throws {
        let original = try codec.read(try Corpus.data("14-headers-footers.docx"))
        var doc = original
        let key = Key(.header, .default)
        doc.headersFooters.stories[key] = edit(try #require(doc.headersFooters.stories[key]), in: doc) {
            replace("Odd page header", with: "Edited header")($0)
        }
        let back = try codec.read(try codec.write(doc))
        #expect(text(back.headersFooters.stories[key]) == "Edited header")
        for name in [
            "word/document.xml", "word/header1.xml", "word/header3.xml", "word/footer1.xml", "word/footer2.xml",
            "[Content_Types].xml", "word/_rels/document.xml.rels",
        ] {
            #expect(back.package[name] == original.package[name], "\(name) changed")
        }
        // The paragraph keeps its style and alignment.
        #expect(part(back, "word/header2.xml").contains(#"<w:pStyle w:val="Header"/>"#))
        #expect(part(back, "word/header2.xml").contains(#"<w:jc w:val="right"/>"#))
    }

    @Test func editingTextAroundAFieldKeepsTheField() throws {
        var doc = try codec.read(try Corpus.data("14-headers-footers.docx"))
        let key = Key(.footer, .default)
        doc.headersFooters.stories[key] = edit(try #require(doc.headersFooters.stories[key]), in: doc) {
            replace("Page ", with: "Página ")($0)
            replace(" of ", with: " de ")($0)
        }
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        let back = try codec.read(data)
        let xml = part(back, "word/footer1.xml")
        #expect(xml.contains(#"<w:fldChar w:fldCharType="begin"/>"#))
        #expect(xml.contains("> PAGE </w:instrText>"))
        #expect(xml.contains(#"w:instr=" NUMPAGES ""#))
        #expect(printed(back.headersFooters.stories[key], page: 2, of: 7) == "Página 2 de 7")
    }

    @Test func newHeaderAndFooterGetPartsAndReferences() throws {
        let original = try codec.read(try Corpus.data("01-plain.docx"))
        var doc = original
        let styleId = doc.styles.styleId(named: "header")
        let header = edit(HeadersFooters.newStory(.header, styleId: styleId), in: doc) { text in
            text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "A new header")
        }
        let footer = edit(HeadersFooters.newStory(.footer, styleId: nil), in: doc) { text in
            let bridge = AttributedStringBridge(doc)
            let attrs = text.attributes(at: 0, effectiveRange: nil)
            text.insert(bridge.pageField(.page, typingAttributes: attrs), at: 0)
            text.insert(NSAttributedString(string: "Page ", attributes: attrs), at: 0)
        }
        doc.headersFooters.stories[Key(.header, .default)] = header
        doc.headersFooters.stories[Key(.footer, .default)] = footer
        // An empty new story makes no part.
        doc.headersFooters.stories[Key(.header, .first)] = HeadersFooters.newStory(.header, styleId: nil)
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.write(doc) == data, "saving the same document twice must give the same file")

        let back = try codec.read(data)
        #expect(Set(back.headersFooters.stories.keys) == [Key(.header, .default), Key(.footer, .default)])
        #expect(text(back.headersFooters.stories[Key(.header, .default)]) == "A new header")
        #expect(back.headersFooters.stories[Key(.header, .default)]?.partName == "word/header1.xml")
        #expect(printed(back.headersFooters.stories[Key(.footer, .default)], page: 3, of: 4) == "Page 3")
        let sect = part(back, "word/document.xml")
        #expect(sect.contains(#"<w:headerReference w:type="default" r:id="#))
        #expect(sect.contains(#"<w:footerReference w:type="default" r:id="#))
        // References come first in w:sectPr.
        #expect(try #require(sect.range(of: "<w:footerReference")).lowerBound < sect.range(of: "<w:pgSz")!.lowerBound)
        #expect(part(back, "[Content_Types].xml").contains("wordprocessingml.header+xml"))
        #expect(part(back, "word/header1.xml").contains(#"<w:pStyle w:val="\#(styleId ?? "")"/>"#))
        // The rest of the body is untouched.
        #expect(back.body.plainText == original.body.plainText)
    }

    @Test func addingAFirstPageHeaderKeepsTheOtherReferences() throws {
        var doc = try codec.read(try Corpus.data("07-header-footer.docx"))
        doc.body.differentFirstPage = true
        doc.headersFooters.stories[Key(.header, .first)] = edit(
            HeadersFooters.newStory(.header, styleId: nil), in: doc
        ) { $0.replaceCharacters(in: NSRange(location: 0, length: 0), with: "First") }
        let back = try codec.read(try codec.write(doc))
        #expect(back.body.differentFirstPage)
        #expect(text(back.headersFooters.story(.header, page: 1, differentFirstPage: true)) == "First")
        #expect(
            text(back.headersFooters.story(.header, page: 2, differentFirstPage: true))?.contains("running header")
                == true)
        #expect(back.headersFooters.stories[Key(.footer, .default)] != nil)
        let xml = part(back, "word/document.xml")
        #expect(xml.components(separatedBy: "<w:headerReference").count == 3)
        #expect(xml.contains("<w:titlePg/>"))
    }

    @Test func differentFirstPageTogglesTitlePg() throws {
        var doc = try codec.read(try Corpus.data("14-headers-footers.docx"))
        doc.body.differentFirstPage = false
        var back = try codec.read(try codec.write(doc))
        #expect(!back.body.differentFirstPage)
        #expect(!part(back, "word/document.xml").contains("titlePg"))
        // The first-page header stays, for Word to use if it's turned on again.
        #expect(back.headersFooters.stories[Key(.header, .first)] != nil)
        back.body.differentFirstPage = true
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        #expect(try #require(xml.range(of: "<w:titlePg/>")).lowerBound < xml.range(of: "<w:docGrid")!.lowerBound)
    }

    @Test func emptySelfClosingStoryParses() throws {
        let xml =
            #"<?xml version="1.0"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>"#
        var body = try DocumentBody(data: Data(xml.utf8), part: "word/header1.xml")
        #expect(body.readOnlyReason == nil)
        #expect(body.blocks.isEmpty)
        body.blocks = [.paragraph(Paragraph(inlines: [.run(Run(text: "x"))]))]
        #expect(
            String(decoding: body.serialized(), as: UTF8.self).hasSuffix("<w:p><w:r><w:t>x</w:t></w:r></w:p></w:hdr>"))
    }
}
