import DocxProbe
import Foundation
import SwiftDocX
import Testing

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/generated")

func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

func allFixtures() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "docx" }
}

/// The corpus itself must be structurally valid, or the evaluation means nothing.
@Suite struct CorpusSanity {
    @Test func corpusIsComplete() throws {
        #expect(try allFixtures().count >= 12)
    }

    @Test(arguments: try allFixtures())
    func fixtureIsAValidPackage(_ url: URL) throws {
        let probe = try DocxProbe(url: url)
        #expect(probe.malformedParts.isEmpty, "\(url.lastPathComponent): \(probe.malformedParts)")
        #expect(probe.packageProblems.isEmpty, "\(url.lastPathComponent): \(probe.packageProblems)")
        #expect(probe.words > 0)
    }

    @Test func probeCountsMatchTheGenerator() throws {
        let headings = try DocxProbe(url: fixture("02-headings.docx"))
        #expect(headings.features[.headingParagraph] == 8)  // Title, Subtitle, Heading 1–6
        let lists = try DocxProbe(url: fixture("03-nested-lists.docx"))
        #expect(lists.features[.listParagraph] == 15)
        let large = try DocxProbe(url: fixture("09-large.docx"))
        #expect(large.words > 60_000)
    }
}

/// Pins the SwiftDocX 1.0.2 findings recorded in ADR 0002. If a SwiftDocX
/// upgrade makes one of these fail, re-run the evaluation and revisit the ADR.
@Suite struct SwiftDocX102Findings {
    @Test func naiveOpenSaveWritesAnEmptyBody() throws {
        let doc = try Document(contentsOf: fixture("01-plain.docx"))
        #expect(doc.paragraphs.count == 8)
        #expect(doc.elements.isEmpty)  // reader fills `paragraphs`; writer emits `elements`
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("naive-\(UUID()).docx")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.write(to: out)
        #expect(try DocxProbe(url: out).words == 0)
    }

    @Test func readerIgnoresStylesListsTablesHyperlinks() throws {
        let headings = try Document(contentsOf: fixture("02-headings.docx"))
        #expect(headings.paragraphs.allSatisfy { $0.headingLevel == nil })
        let lists = try Document(contentsOf: fixture("03-nested-lists.docx"))
        #expect(lists.paragraphs.allSatisfy { $0.listType == nil })
        let tables = try Document(contentsOf: fixture("04-tables.docx"))
        #expect(tables.tables.isEmpty)
        let links = try Document(contentsOf: fixture("06-hyperlinks.docx"))
        #expect(links.paragraphs.flatMap(\.runs).allSatisfy { $0.hyperlink == nil })
    }

    @Test func writerDropsPartsItDoesNotOwn() throws {
        let src = try DocxProbe(url: fixture("10-word-features.docx"))
        let doc = try Document(contentsOf: fixture("10-word-features.docx"))
        doc.elements = doc.paragraphs.map { .paragraph($0) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rebuilt-\(UUID()).docx")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.write(to: out)
        let diff = PackageDiff(from: src, to: try DocxProbe(url: out))
        #expect(diff.dropped.contains("word/footnotes.xml"))
        #expect(diff.dropped.contains("word/comments.xml"))
        #expect(diff.dropped.contains("customXml/item1.xml"))
        #expect(diff.identical.isEmpty)
    }
}
