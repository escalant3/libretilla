import Foundation
import Testing

@testable import CartillaDocx

@Suite struct PageSetupTests {
    let codec = OOXMLCodec()

    func sectPr(_ doc: DocxDocument) -> String? {
        guard let i = doc.body.sectionPropertiesIndex, case .opaque(let o) = doc.body.blocks[i] else { return nil }
        return String(decoding: o.xml, as: UTF8.self)
    }

    @Test func readsLetterAndA4() throws {
        let letter = try codec.read(try Corpus.data("01-plain.docx")).body.pageSetup
        #expect(letter == .letter)
        #expect(letter.pageSize == CGSize(width: 612, height: 792))
        #expect(letter.textWidth == 468)

        let a4 = try codec.read(try Corpus.data("07-header-footer.docx")).body.pageSetup
        #expect(a4.width == 11906 && a4.height == 16838)
        #expect(a4.margins.left == 72)
    }

    @Test func readsPagesOrientationAndOddSizes() throws {
        let pages = try codec.read(try Corpus.data("12-pages.docx")).body.pageSetup
        #expect(pages.height == 14240)
        #expect(!pages.isLandscape)
    }

    @Test func sectionWithoutPageSizeIsLetter() throws {
        // pandoc writes a w:sectPr with only footnote settings.
        let doc = try codec.read(try Corpus.data("11-pandoc.docx"))
        #expect(try #require(sectPr(doc)).contains("w:footnotePr"))
        #expect(doc.body.pageSetup == .letter)
    }

    @Test func pageSizeAndMarginsGoAfterFootnoteSettings() throws {
        var doc = try codec.read(try Corpus.data("11-pandoc.docx"))
        doc.body.pageSetup = .a4
        let xml = try #require(sectPr(doc))
        let footnotes = try #require(xml.range(of: "</w:footnotePr>"))
        let size = try #require(xml.range(of: #"<w:pgSz w:w="11906" w:h="16838"/>"#))
        let margins = try #require(
            xml.range(
                of:
                    #"<w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701" w:header="720" w:footer="720" w:gutter="0"/>"#
            ))
        #expect(footnotes.upperBound <= size.lowerBound && size.upperBound <= margins.lowerBound)
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.read(data).body.pageSetup == .a4)
    }

    @Test func changingMarginsRewritesOnlyThoseAttributes() throws {
        var doc = try codec.read(try Corpus.data("07-header-footer.docx"))
        let before = try #require(sectPr(doc))
        var setup = doc.body.pageSetup
        setup.left = 1701
        setup.right = 1701
        doc.body.pageSetup = setup

        let after = try #require(sectPr(doc))
        #expect(
            after
                == before.replacingOccurrences(
                    of: #"w:right="1440" w:bottom="1440" w:left="1440""#,
                    with: #"w:right="1701" w:bottom="1440" w:left="1701""#))
        // Header/footer references and everything else are untouched; the file reopens with the change.
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.read(data).body.pageSetup == setup)
    }

    @Test func landscapeSwapsTheSizeAndSetsOrient() throws {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        var setup = doc.body.pageSetup
        (setup.width, setup.height, setup.isLandscape) = (setup.height, setup.width, true)
        doc.body.pageSetup = setup
        #expect(try #require(sectPr(doc)).contains(#"<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>"#))

        setup.isLandscape = false
        (setup.width, setup.height) = (setup.height, setup.width)
        doc.body.pageSetup = setup
        #expect(try #require(sectPr(doc)).contains(#"<w:pgSz w:w="12240" w:h="15840"/>"#))
    }

    @Test func settingAPageSetupCreatesSectionPropertiesWhenMissing() throws {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        doc.body.blocks.remove(at: try #require(doc.body.sectionPropertiesIndex))
        #expect(doc.body.pageSetup == .letter)
        doc.body.pageSetup = .a4
        #expect(
            try #require(sectPr(doc))
                == #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>"#
                + #"<w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#
        )
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.read(data).body.pageSetup == .a4)
    }

    @Test func settingTheSameSetupChangesNothing() throws {
        var doc = try codec.read(try Corpus.data("12-pages.docx"))
        let original = try Corpus.data("12-pages.docx")
        doc.body.pageSetup = doc.body.pageSetup
        #expect(try codec.write(doc) == original)
    }

    @Test func negativeTopMarginKeepsItsSign() throws {
        var doc = try codec.read(try Corpus.data("01-plain.docx"))
        var setup = doc.body.pageSetup
        setup.top = -1440
        doc.body.pageSetup = setup
        #expect(doc.body.pageSetup.margins.top == 72)
        setup = doc.body.pageSetup
        setup.top = 720
        doc.body.pageSetup = setup
        #expect(try #require(sectPr(doc)).contains(#"w:top="-720""#))
    }
}
