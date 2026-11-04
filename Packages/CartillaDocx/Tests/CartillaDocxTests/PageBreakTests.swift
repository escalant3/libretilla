import AppKit
import Foundation
import Testing

@testable import CartillaDocx

@MainActor
@Suite struct PageBreakTests {
    let codec = OOXMLCodec()

    func load(_ data: Data) throws -> (DocxDocument, AttributedStringBridge, NSMutableAttributedString) {
        let doc = try codec.read(data)
        let bridge = AttributedStringBridge(doc)
        return (doc, bridge, NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body)))
    }

    func save(_ doc: DocxDocument, _ bridge: AttributedStringBridge, _ text: NSAttributedString) throws -> DocxDocument
    {
        var out = doc
        out.body = bridge.body(from: text, base: doc.body).body
        let data = try codec.write(out)
        #expect(try PackageChecker.problems(data).isEmpty)
        return try codec.read(data)
    }

    func pageBreaks(in text: NSAttributedString) -> [Int] {
        var at: [Int] = []
        text.enumerateAttribute(.cartillaPageBreak, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            if v != nil { at += Array(r.location..<NSMaxRange(r)) }
        }
        return at
    }

    func documentXML(_ doc: DocxDocument) -> String { String(decoding: doc.body.serialized(), as: UTF8.self) }

    /// A one-paragraph document with this body XML.
    func document(_ body: String) throws -> Data {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        let xml = String(decoding: doc.body.serialized(), as: UTF8.self)
        let start = try #require(xml.range(of: "<w:body>")).upperBound
        let end = try #require(xml.range(of: "<w:sectPr>")).lowerBound
        doc.package.setPart(doc.mainPartName, data: Data(xml.replacingCharacters(in: start..<end, with: body).utf8))
        return try doc.package.serialized()
    }

    @Test func wordPageBreaksAreRunCharactersShownAsChips() throws {
        let (doc, _, text) = try load(try Corpus.data("07-header-footer.docx"))
        let breaks = pageBreaks(in: text)
        #expect(breaks.count == 3)
        for i in breaks {
            #expect(text.attribute(.attachment, at: i, effectiveRange: nil) != nil)
            #expect(text.attribute(.cartillaOpaque, at: i, effectiveRange: nil) == nil)
        }
        #expect(doc.body.plainText.filter { $0 == Run.pageBreak }.count == 3)
    }

    @Test func editingAParagraphKeepsItsPageBreak() throws {
        let data = try document(#"<w:p><w:r><w:t>Before</w:t><w:br w:type="page"/><w:t>after</w:t></w:r></w:p>"#)
        let (doc, bridge, text) = try load(data)
        // Previously this run became a "Page break" chip that hid its text.
        #expect(text.string.hasPrefix("Before\u{FFFC}after"))
        text.replaceCharacters(in: NSRange(location: 0, length: 6), with: "Antes")
        let back = try save(doc, bridge, text)
        #expect(documentXML(back).contains(#"<w:t>Antes</w:t><w:br w:type="page"/><w:t>after</w:t>"#))
    }

    @Test func insertedPageBreakIsSavedWithTheRunsFormatting() throws {
        let (doc, bridge, text) = try load(try Corpus.data("01-plain.docx"))
        let at = (text.string as NSString).range(of: "plain paragraph").location
        let typing = text.attributes(at: at, effectiveRange: nil)
        text.insert(AttributedStringBridge.pageBreak(typingAttributes: typing), at: at)
        #expect(pageBreaks(in: text) == [at])

        let back = try save(doc, bridge, text)
        let p = try #require(
            back.body.blocks.lazy.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
                .first { $0.text.contains("plain paragraph") })
        #expect(p.text.contains("This is a \u{000C}plain paragraph"))
        #expect(String(decoding: p.serialized(), as: UTF8.self).contains(#"<w:br w:type="page"/>"#))
        // Reopening shows it again as a page break.
        let (_, _, reopened) = try load(try codec.write(back))
        #expect(pageBreaks(in: reopened).count == 1)
    }

    @Test func deletingAPageBreakRemovesIt() throws {
        let (doc, bridge, text) = try load(try Corpus.data("07-header-footer.docx"))
        let first = try #require(pageBreaks(in: text).first)
        text.deleteCharacters(in: NSRange(location: first, length: 1))
        let back = try save(doc, bridge, text)
        #expect(back.body.plainText.filter { $0 == Run.pageBreak }.count == 2)
    }

    @Test func pageBreakAttributesAreNotInheritedByTypedText() {
        let typing: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let pb = AttributedStringBridge.pageBreak(typingAttributes: typing)
        var attrs = pb.attributes(at: 0, effectiveRange: nil)
        for key in NSAttributedString.Key.cartillaNonInheritable { attrs[key] = nil }
        #expect(attrs[.cartillaPageBreak] == nil && attrs[.attachment] == nil)
        #expect(attrs[.font] != nil)
    }
}
