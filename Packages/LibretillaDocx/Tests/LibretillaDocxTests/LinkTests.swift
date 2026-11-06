import AppKit
import Foundation
import Testing

@testable import LibretillaDocx

@MainActor
@Suite struct LinkTests {
    let codec = OOXMLCodec()

    struct Loaded {
        var doc: DocxDocument
        var bridge: AttributedStringBridge
        var text: NSMutableAttributedString
    }

    func load(_ name: String) throws -> Loaded { try load(try Corpus.data(name)) }

    func load(_ data: Data) throws -> Loaded {
        let doc = try codec.read(data)
        let bridge = AttributedStringBridge(doc)
        return Loaded(
            doc: doc, bridge: bridge,
            text: NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body)))
    }

    /// Saves (twice, as autosave would, from the same base) and returns the second result.
    func save(_ l: Loaded) throws -> (DocxDocument, Data) {
        var out = l.doc
        out.styles = l.bridge.styles
        out.body = l.bridge.body(from: l.text, base: l.doc.body).body
        let first = try codec.write(out)
        let data = try codec.write(out)
        #expect(first == data, "saving the same edit twice gives the same file")
        #expect(try PackageChecker.problems(data).isEmpty)
        return (try codec.read(data), data)
    }

    func range(of s: String, in text: NSAttributedString) throws -> NSRange {
        let r = (text.string as NSString).range(of: s)
        try #require(r.location != NSNotFound, "\(s) not found")
        return r
    }

    func linkXML(containing s: String, in doc: DocxDocument) throws -> String {
        let xml = String(decoding: doc.body.serialized(), as: UTF8.self)
        let at = try #require(xml.range(of: s)).lowerBound
        let open = try #require(xml.range(of: "<w:hyperlink", options: .backwards, range: xml.startIndex..<at))
        let close = try #require(xml.range(of: "</w:hyperlink>", range: at..<xml.endIndex))
        return String(xml[open.lowerBound..<close.upperBound])
    }

    func hyperlinkRelationships(_ data: Data) throws -> [Relationship] {
        try OPCPackage(data: data).relationships(of: "word/document.xml").filter {
            $0.type == OOXMLCodec.hyperlinkType
        }
    }

    @Test func wordLinksShowWithTheirURL() throws {
        let l = try load("06-hyperlinks.docx")
        let at = try range(of: "example.com", in: l.text).location
        let url = l.text.attribute(.link, at: at, effectiveRange: nil) as? URL
        #expect(url?.host() == "example.com")
        let found = try #require(AttributedStringBridge.link(at: at + 3, in: l.text))
        #expect((l.text.string as NSString).substring(with: found.range) == "example.com")
        // Bookmark links are modelled too, without a URL.
        let bookmark = try range(of: "bookmark", in: l.text).location
        let box = try #require(
            l.text.attribute(.libretillaHyperlink, at: bookmark, effectiveRange: nil) as? HyperlinkBox)
        #expect(box.link.anchor == "target" && box.url == nil)
    }

    @Test func selectionBecomesALinkWithOneRelationship() throws {
        var l = try load("01-plain.docx")
        let r = try range(of: "plain paragraph", in: l.text)
        let style = l.bridge.styles.styleId(named: "Hyperlink", type: "character")
        l.bridge.setLink("https://libretilla.app/docs", in: l.text, range: r, hyperlinkStyleId: style)
        let (back, data) = try save(l)

        let xml = try linkXML(containing: "plain paragraph", in: back)
        #expect(xml.hasPrefix(#"<w:hyperlink r:id="#) && xml.contains(#"w:history="1""#))
        #expect(xml.contains(#"<w:rStyle w:val="Hyperlink"/>"#))
        let rels = try hyperlinkRelationships(data)
        #expect(rels.count == 1)
        #expect(rels.first?.target == "https://libretilla.app/docs" && rels.first?.isExternal == true)
        #expect(xml.contains("r:id=\"\(rels[0].id)\""))

        // Reopened, it's a link to the same place.
        l = try load(data)
        let at = try range(of: "plain paragraph", in: l.text).location
        #expect(
            (l.text.attribute(.link, at: at, effectiveRange: nil) as? URL)?.absoluteString
                == "https://libretilla.app/docs")
    }

    @Test func twoLinksToTheSameURLShareARelationship() throws {
        let l = try load("01-plain.docx")
        for s in ["plain", "Normal style"] {
            l.bridge.setLink(
                "https://example.org", in: l.text, range: try range(of: s, in: l.text), hyperlinkStyleId: nil)
        }
        let (_, data) = try save(l)
        #expect(try hyperlinkRelationships(data).count == 1)
    }

    @Test func retargetingKeepsTheLinksOtherAttributes() throws {
        let l = try load("06-hyperlinks.docx")
        let found = try #require(
            AttributedStringBridge.link(at: try range(of: "example.com", in: l.text).location, in: l.text))
        l.bridge.setLink("https://libretilla.app", in: l.text, range: found.range, hyperlinkStyleId: nil)
        let (back, data) = try save(l)
        let xml = try linkXML(containing: "example.com", in: back)
        let id = try #require(try hyperlinkRelationships(data).first { $0.target == "https://libretilla.app" }?.id)
        #expect(xml.contains("r:id=\"\(id)\""))
        #expect(xml.contains(#"w:history="1""#))
    }

    @Test func removingALinkKeepsTheTextWithoutTheLinkStyle() throws {
        let l = try load("06-hyperlinks.docx")
        let found = try #require(
            AttributedStringBridge.link(at: try range(of: "example.com", in: l.text).location, in: l.text))
        let style = l.bridge.styles.styleId(named: "Hyperlink", type: "character")
        l.bridge.removeLinks(in: l.text, range: found.range, hyperlinkStyleId: style)
        #expect(l.text.attribute(.link, at: found.range.location, effectiveRange: nil) == nil)
        let (back, _) = try save(l)
        let p = try #require(
            back.body.blocks.lazy.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
                .first { $0.text.contains("example.com for") })
        let xml = String(decoding: p.serialized(), as: UTF8.self)
        #expect(!xml.contains("<w:hyperlink"))
        #expect(!xml.contains("Hyperlink"))
        #expect(p.text.contains("Visit example.com for details."))
    }

    @Test func insertedLinkTextIsALink() throws {
        let l = try load("01-plain.docx")
        let at = try range(of: "plain paragraph", in: l.text).location
        let typing = l.text.attributes(at: at, effectiveRange: nil)
        let style = l.bridge.styles.styleId(named: "Hyperlink", type: "character")
        let link = try #require(
            l.bridge.linkText(
                "Libretilla", url: "https://libretilla.app", typingAttributes: typing, paragraphStyle: nil,
                hyperlinkStyleId: style))
        l.text.insert(link, at: at)
        let (back, _) = try save(l)
        let xml = try linkXML(containing: "Libretilla<", in: back)
        #expect(xml.contains(#"<w:rStyle w:val="Hyperlink"/>"#))
    }

    @Test func aLinkInADocumentWithoutTheRelationshipsNamespaceDeclaresIt() throws {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        let xml = String(decoding: doc.body.serialized(), as: UTF8.self)
        let declaration = #" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        try #require(xml.contains(declaration))
        doc.package.setPart(doc.mainPartName, data: Data(xml.replacingOccurrences(of: declaration, with: "").utf8))
        let l = try load(try doc.package.serialized())
        l.bridge.setLink(
            "https://example.org", in: l.text, range: try range(of: "plain", in: l.text), hyperlinkStyleId: nil)
        let (back, _) = try save(l)
        let out = String(decoding: back.body.serialized(), as: UTF8.self)
        #expect(out.components(separatedBy: declaration).count == 2)
    }

    @Test func linksWithFieldsOrBookmarksInsideStayOpaque() throws {
        // 10-word-features has none of these; build one.
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        let xml = String(decoding: doc.body.serialized(), as: UTF8.self)
        let start = try #require(xml.range(of: "<w:body>")).upperBound
        let end = try #require(xml.range(of: "<w:sectPr>")).lowerBound
        let body =
            #"<w:p><w:hyperlink r:id="rId99"><w:bookmarkStart w:id="1" w:name="x"/><w:r><w:t>odd</w:t></w:r>"#
            + #"<w:bookmarkEnd w:id="1"/></w:hyperlink></w:p>"#
        doc.package.setPart(doc.mainPartName, data: Data(xml.replacingCharacters(in: start..<end, with: body).utf8))
        let l = try load(try doc.package.serialized())
        let at = try range(of: "odd", in: l.text).location
        #expect(l.text.attribute(.libretillaOpaque, at: at, effectiveRange: nil) != nil)
        #expect(l.text.attribute(.libretillaHyperlink, at: at, effectiveRange: nil) == nil)
    }
}
