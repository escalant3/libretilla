import AppKit
import Foundation
import Testing

@testable import LibretillaDocx

@MainActor
@Suite struct BridgeTests {
    let codec = OOXMLCodec()

    func load(_ name: String) throws -> (DocxDocument, AttributedStringBridge, NSMutableAttributedString) {
        let doc = try codec.read(try Corpus.data(name))
        let bridge = AttributedStringBridge(styles: doc.styles)
        return (doc, bridge, NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body)))
    }

    func save(_ doc: DocxDocument, _ bridge: AttributedStringBridge, _ text: NSAttributedString) throws
        -> (DocxDocument, [String])
    {
        var out = doc
        let result = bridge.body(from: text, base: doc.body)
        out.body = result.body
        let data = try codec.write(out)
        #expect(try PackageChecker.problems(data).isEmpty)
        return (try codec.read(data), result.notices)
    }

    /// Mimics NSTextView typing: new text takes the attributes before the insertion point,
    /// minus the non-inheritable ones.
    func type(_ s: String, at location: Int, in text: NSMutableAttributedString) {
        var attrs = text.attributes(at: max(0, location - 1), effectiveRange: nil)
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        text.insert(NSAttributedString(string: s, attributes: attrs), at: location)
    }

    func location(of s: String, in text: NSAttributedString) throws -> Int {
        let r = (text.string as NSString).range(of: s)
        try #require(r.location != NSNotFound, "\(s) not found")
        return r.location
    }

    @Test(arguments: Corpus.all)
    func uneditedTextMapsBackToIdenticalDocumentXML(_ url: URL) throws {
        let doc = try codec.read(try Data(contentsOf: url))
        let bridge = AttributedStringBridge(styles: doc.styles)
        let text = bridge.attributedString(for: doc.body)
        let back = bridge.body(from: text, base: doc.body)
        #expect(back.notices.isEmpty)
        #expect(back.body.serialized() == doc.package[doc.mainPartName], "\(url.lastPathComponent)")
    }

    @Test func typingInsideARunKeepsItsFormattingAndTouchesOnlyThatParagraph() throws {
        let (doc, bridge, text) = try load("01-plain.docx")
        type("very ", at: try location(of: "bold", in: text) + 0, in: text)
        // Inserting at the start of "bold" inherits the run before it (plain); insert inside instead.
        type("ly", at: try location(of: "bold", in: text) + 4, in: text)
        let (back, notices) = try save(doc, bridge, text)
        #expect(notices.isEmpty)
        #expect(back.body.plainText.contains("very boldly"))
        let runs = back.body.blocks.flatMap { b -> [Run] in
            guard case .paragraph(let p) = b else { return [] }
            return p.inlines.compactMap { if case .run(let r) = $0 { r } else { nil } }
        }
        #expect(runs.contains { $0.text == "boldly" && $0.properties.bold == true })
        // Every other paragraph is byte-identical.
        let changed = zip(doc.body.blocks, back.body.blocks).filter { $0.serialized() != $1.serialized() }
        #expect(changed.count == 1)
    }

    @Test func enterInASectionBreakParagraphKeepsExactlyOneSectionBreak() throws {
        let (doc, bridge, text) = try load("10-word-features.docx")
        let at = try location(of: "End of single-column section.", in: text) + 7
        type("\n", at: at, in: text)
        let (back, _) = try save(doc, bridge, text)
        let breaks = back.body.blocks.filter {
            if case .paragraph(let p) = $0 { p.properties.hasSectionBreak } else { false }
        }
        #expect(breaks.count == 1)
        #expect(back.body.plainText.contains("End of \nsingle-column section."))
        #expect(String(decoding: back.body.serialized(), as: UTF8.self).components(separatedBy: "<w:sectPr").count == 3)
    }

    @Test func editingInsideAHyperlinkKeepsTheLink() throws {
        let (doc, bridge, text) = try load("06-hyperlinks.docx")
        let before = String(decoding: doc.body.serialized(), as: UTF8.self)
        let at = try location(of: "example.com for", in: text)
        text.replaceCharacters(in: NSRange(location: at, length: 7), with: "sample")
        let (back, notices) = try save(doc, bridge, text)
        #expect(back.body.plainText.contains("Visit sample.com for details."))
        #expect(notices.isEmpty)
        // Still a link to the same relationship, now with the edited text; the other links are untouched.
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        #expect(
            xml.components(separatedBy: "<w:hyperlink").count == before.components(separatedBy: "<w:hyperlink").count)
        let edited = try #require(xml.range(of: "sample.com")).lowerBound
        let open = try #require(xml.range(of: "<w:hyperlink", options: .backwards, range: xml.startIndex..<edited))
        #expect(xml[open.lowerBound..<edited].contains("r:id="))
        #expect(!xml[open.lowerBound..<edited].contains("</w:hyperlink>"))
    }

    @Test func typingAfterAHyperlinkDoesNotJoinIt() throws {
        let (doc, bridge, text) = try load("06-hyperlinks.docx")
        type("!", at: try location(of: " for details.", in: text), in: text)
        let (back, notices) = try save(doc, bridge, text)
        #expect(notices.isEmpty)
        #expect(back.body.plainText.contains("Visit example.com! for details."))
        #expect(
            String(decoding: back.body.serialized(), as: UTF8.self).components(separatedBy: "<w:hyperlink").count == 5)
    }

    @Test func tablesSurviveEditsAroundThemAndCanBeDeleted() throws {
        let (doc, bridge, text) = try load("04-tables.docx")
        type(" Edited.", at: try location(of: "After the tables.", in: text) + 17, in: text)
        let (back, _) = try save(doc, bridge, text)
        let original = String(decoding: doc.body.serialized(), as: UTF8.self)
        let saved = String(decoding: back.body.serialized(), as: UTF8.self)
        #expect(saved.components(separatedBy: "<w:tbl>").count == original.components(separatedBy: "<w:tbl>").count)
        #expect(back.body.plainText.contains("After the tables. Edited."))

        // Delete the first table: all its row lines, and the line break after the last one.
        let attachment = try location(of: "\u{FFFC}", in: text)
        var whole = NSRange()
        _ = text.attribute(
            .libretillaBlock, at: attachment, longestEffectiveRange: &whole,
            in: NSRange(location: 0, length: text.length)
        )
        text.deleteCharacters(in: NSRange(location: whole.location, length: whole.length + 1))
        let (fewer, _) = try save(doc, bridge, text)
        let tables = fewer.body.blocks.filter { if case .opaque(let o) = $0 { o.kind == "w:tbl" } else { false } }
        #expect(tables.count == 1)
    }

    @Test func textTypedBeforeATablePlaceholderKeepsTheTable() throws {
        let (doc, bridge, text) = try load("04-tables.docx")
        let attachment = try location(of: "\u{FFFC}", in: text)
        text.insert(NSAttributedString(string: "Intro "), at: attachment)
        let (back, _) = try save(doc, bridge, text)
        let tables = back.body.blocks.filter { if case .opaque(let o) = $0 { o.kind == "w:tbl" } else { false } }
        #expect(tables.count == 2)
        #expect(back.body.plainText.contains("Intro "))
    }

    @Test func wordFeaturesSurviveAnEditElsewhere() throws {
        let (doc, bridge, text) = try load("10-word-features.docx")
        type(" More.", at: try location(of: "Word-only features", in: text) + 18, in: text)
        let (back, notices) = try save(doc, bridge, text)
        #expect(notices.isEmpty)
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        for marker in [
            "w:footnoteReference", "w:commentRangeStart", "w:commentReference", "<w:ins ", "<w:del ",
            "w:fldSimple", "w:fldChar", "<w:sdt>", "w:txbxContent", "m:oMath", "w:cols w:num=\"2\"",
        ] {
            #expect(xml.contains(marker), "\(marker) lost")
        }
    }

    @Test func pastedTextWithoutSourceRunsGetsFormattingFromItsFont() throws {
        let (doc, bridge, text) = try load("01-plain.docx")
        let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask)
        text.append(NSAttributedString(string: "Pasted bold\n", attributes: [.font: bold]))
        let (back, _) = try save(doc, bridge, text)
        guard case .paragraph(let p) = back.body.blocks.dropLast().last else { Issue.record("no paragraph"); return }
        #expect(p.text == "Pasted bold")
        if case .run(let r) = p.inlines.first { #expect(r.properties.bold == true) }
    }

    @Test func clearingEverythingStillWritesOneParagraph() throws {
        let (doc, bridge, _) = try load("01-plain.docx")
        let (back, _) = try save(doc, bridge, NSAttributedString())
        let paragraphs = back.body.blocks.filter { if case .paragraph = $0 { true } else { false } }
        #expect(paragraphs.count == 1)
        #expect(back.body.blocks.contains { if case .opaque(let o) = $0 { o.isSectionProperties } else { false } })
    }

    @Test func headingsDisplayLargerAndBold() throws {
        let (_, _, text) = try load("02-headings.docx")
        let at = try location(of: "Heading 1", in: text)
        let font = try #require(text.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 16)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test func outlineLevelsFollowWordsHeadingNames() throws {
        let (doc, _, _) = try load("02-headings.docx")
        let styles = doc.styles
        let heading1 = try #require(styles.styleId(named: "heading 1"))
        let heading2 = try #require(styles.styleId(named: "heading 2"))
        #expect(styles.outlineLevel(ofParagraphStyle: heading1) == 1)
        #expect(styles.outlineLevel(ofParagraphStyle: heading2) == 2)
        #expect(styles.outlineLevel(ofParagraphStyle: nil) == nil, "Normal is body text")
        if let title = styles.styleId(named: "Title") { #expect(styles.outlineLevel(ofParagraphStyle: title) == 0) }
        #expect(StyleSheet.outlineLevel(name: "Heading 10") == nil)
        #expect(StyleSheet.outlineLevel(name: "heading") == nil)
    }
}
