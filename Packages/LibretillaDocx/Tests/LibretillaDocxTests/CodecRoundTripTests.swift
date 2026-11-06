import Foundation
import Testing

@testable import LibretillaDocx

/// The round-trip contract (ADR 0002), checked over the whole fixture corpus.
@Suite struct CodecRoundTripTests {
    let codec = OOXMLCodec()

    @Test func corpusIsPresent() { #expect(Corpus.all.count >= 12) }

    @Test(arguments: Corpus.all)
    func unchangedDocumentReassemblesByteForByte(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let doc = try codec.read(data)
        #expect(doc.readOnlyReason == nil, "\(url.lastPathComponent): \(doc.readOnlyReason ?? "")")
        #expect(doc.body.serialized() == doc.package[doc.mainPartName], "document.xml reassembly differs")
        #expect(try codec.write(doc) == data, "unedited write must return the original file")
    }

    /// Re-serializing *every* paragraph from its parts (as if all were edited) must keep the
    /// text, the run formatting and every other part, and produce a valid package.
    @Test(arguments: Corpus.all)
    func fullyReserializedDocumentKeepsContent(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var doc = try codec.read(data)
        doc.body.blocks = doc.body.blocks.map {
            if case .paragraph(let p) = $0 { .paragraph(p.edited()) } else { $0 }
        }
        let out = try codec.write(doc)
        let back = try codec.read(out)

        #expect(back.body.plainText == doc.body.plainText)
        #expect(back.body.blocks.count == doc.body.blocks.count)
        for (a, b) in zip(doc.body.blocks, back.body.blocks) {
            guard case .paragraph(let pa) = a, case .paragraph(let pb) = b else { continue }
            #expect(pa.properties == pb.properties)
            #expect(pa.inlines.count == pb.inlines.count || pa.text.isEmpty)
            for (ia, ib) in zip(pa.inlines, pb.inlines) {
                if case .run(let ra) = ia, case .run(let rb) = ib { #expect(ra.properties == rb.properties) }
            }
        }
        // Only the main document part may change.
        let original = try OPCPackage(data: data)
        let written = try OPCPackage(data: out)
        #expect(written.partNames == original.partNames)
        for part in original.parts where part.name != doc.mainPartName {
            #expect(written[part.name] == part.data, "\(part.name) changed")
        }
        #expect(try PackageChecker.problems(out).isEmpty)
    }

    @Test func editingOneParagraphChangesOnlyThatParagraph() throws {
        let data = try Corpus.data("08-spanish.docx")
        var doc = try codec.read(data)
        guard case .paragraph(var p) = doc.body.blocks[2] else { Issue.record("expected a paragraph"); return }
        p = p.edited()
        p.inlines = [.run(Run(text: "Texto nuevo: «¿qué tal?» & <ñ>"))]
        doc.body.blocks[2] = .paragraph(p)
        let back = try codec.read(try codec.write(doc))
        guard case .paragraph(let q) = back.body.blocks[2] else { Issue.record("expected a paragraph"); return }
        #expect(q.text == "Texto nuevo: «¿qué tal?» & <ñ>")
        for i in back.body.blocks.indices where i != 2 {
            #expect(back.body.blocks[i].serialized() == doc.body.blocks[i].serialized())
        }
    }

    @Test func sectionBreakCanBeDroppedFromADuplicatedParagraph() throws {
        let doc = try codec.read(try Corpus.data("10-word-features.docx"))
        let withBreak = doc.body.blocks.compactMap { b -> Paragraph? in
            if case .paragraph(let p) = b, p.properties.hasSectionBreak { p } else { nil }
        }
        let p = try #require(withBreak.first).edited()
        let xml = String(decoding: p.serialized(keepSectionBreak: false), as: UTF8.self)
        #expect(!xml.contains("w:sectPr"))
        #expect(String(decoding: p.serialized(), as: UTF8.self).contains("w:sectPr"))
    }
}

@Suite struct ParsingTests {
    let codec = OOXMLCodec()

    @Test func runFormattingAndParagraphProperties() throws {
        let doc = try codec.read(try Corpus.data("01-plain.docx"))
        let runs = doc.body.blocks.flatMap { b -> [Run] in
            guard case .paragraph(let p) = b else { return [] }
            return p.inlines.compactMap { if case .run(let r) = $0 { r } else { nil } }
        }
        #expect(runs.contains { $0.text == "bold" && $0.properties.bold == true })
        #expect(runs.contains { $0.text == "italic" && $0.properties.italic == true })
        #expect(runs.contains { $0.text == "red" && $0.properties.color == "C00000" })
        #expect(runs.contains { $0.properties.size == 14 && $0.properties.font == "Times New Roman" })
        #expect(runs.contains { $0.text.contains("\t") })
        let centered = doc.body.blocks.contains {
            if case .paragraph(let p) = $0 { p.properties.alignment == "center" } else { false }
        }
        #expect(centered)
    }

    @Test func stylesResolveThroughBasedOnAndTheme() throws {
        let doc = try codec.read(try Corpus.data("02-headings.docx"))
        let (_, heading1) = doc.styles.resolveParagraphStyle("Heading1")
        #expect(heading1.size == 16)
        #expect(heading1.bold == true)
        #expect(doc.styles.fontFamily(for: heading1) == "Calibri Light")
        let (_, normal) = doc.styles.resolveParagraphStyle(nil)
        #expect(normal.size == 11)
        #expect(doc.styles.fontFamily(for: normal) == "Calibri")
    }

    @Test func unmodelledContentIsOpaque() throws {
        let doc = try codec.read(try Corpus.data("10-word-features.docx"))
        let opaque = doc.body.blocks.flatMap { b -> [OpaqueInline] in
            guard case .paragraph(let p) = b else { return [] }
            return p.inlines.compactMap { if case .opaque(let o) = $0 { o } else { nil } }
        }
        let kinds = Set(opaque.map(\.kind))
        #expect(kinds.isSuperset(of: ["w:ins", "w:del", "w:fldSimple", "w:sdt", "w:commentRangeStart", "m:oMath"]))
        #expect(opaque.contains { $0.display == .object(label: "Footnote") })
        #expect(opaque.contains { $0.display == .object(label: "Text box") })
        #expect(opaque.contains { $0.kind == "w:del" && $0.display == .invisible })
        #expect(opaque.contains { $0.kind == "w:ins" && $0.display == .text("inserted text") })

        let hyperlinks = try codec.read(try Corpus.data("06-hyperlinks.docx"))
        #expect(hyperlinks.body.plainText.contains("Visit example.com for details."))

        let tables = try codec.read(try Corpus.data("04-tables.docx"))
        let summaries = tables.body.blocks.compactMap { b -> String? in
            if case .opaque(let o) = b { o.summary } else { nil }
        }
        #expect(summaries.contains("Table, 7 × 3"))
    }
}
