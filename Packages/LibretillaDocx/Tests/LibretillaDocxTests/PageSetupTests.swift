import Foundation
import Testing

@testable import LibretillaDocx

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

    @Test func sectionWithoutPageSizeIsA4() throws {
        // pandoc writes a w:sectPr with only footnote settings.
        let doc = try codec.read(try Corpus.data("11-pandoc.docx"))
        #expect(try #require(sectPr(doc)).contains("w:footnotePr"))
        #expect(doc.body.pageSetup == .a4)
    }

    @Test func pageSizeAndMarginsGoAfterFootnoteSettings() throws {
        var doc = try codec.read(try Corpus.data("11-pandoc.docx"))
        doc.body.pageSetup = .letter
        let xml = try #require(sectPr(doc))
        let footnotes = try #require(xml.range(of: "</w:footnotePr>"))
        let size = try #require(xml.range(of: #"<w:pgSz w:w="12240" w:h="15840"/>"#))
        let margins = try #require(
            xml.range(
                of:
                    #"<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>"#
            ))
        #expect(footnotes.upperBound <= size.lowerBound && size.upperBound <= margins.lowerBound)
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.read(data).body.pageSetup == .letter)
    }

    @Test func changingOnlyMarginsWritesTheAssumedPageSizeToo() throws {
        // Without w:pgSz, Word would pick its own locale's paper; write the A4 Libretilla showed.
        var doc = try codec.read(try Corpus.data("11-pandoc.docx"))
        var setup = doc.body.pageSetup
        setup.left = 1440
        doc.body.pageSetup = setup
        #expect(try #require(sectPr(doc)).contains(#"<w:pgSz w:w="11906" w:h="16838"/>"#))
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
        #expect(doc.body.pageSetup == .fallback)
        doc.body.pageSetup = .letter
        #expect(
            try #require(sectPr(doc))
                == #"<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>"#
                + #"<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#
        )
        let data = try codec.write(doc)
        #expect(try PackageChecker.problems(data).isEmpty)
        #expect(try codec.read(data).body.pageSetup == .letter)
    }

    @Test func settingTheSameSetupChangesNothing() throws {
        var doc = try codec.read(try Corpus.data("12-pages.docx"))
        let original = try Corpus.data("12-pages.docx")
        doc.body.pageSetup = doc.body.pageSetup
        #expect(try codec.write(doc) == original)
    }

    @Test func paperFromAppKitSnapsToWordsExactSizes() {
        // AppKit rounds A4 to 595 × 842 points.
        let a4 = PageSetup.letter.withPaper(CGSize(width: 595, height: 842), landscape: false)
        #expect((a4.width, a4.height) == (11906, 16838))
        #expect(a4.margins.left == 72)
        let landscape = PageSetup.letter.withPaper(CGSize(width: 842, height: 595), landscape: true)
        #expect((landscape.width, landscape.height, landscape.isLandscape) == (16838, 11906, true))
        // Some printers report a landscape page tall; it's turned to lie wide.
        let turned = PageSetup.letter.withPaper(CGSize(width: 612, height: 792), landscape: true)
        #expect((turned.width, turned.height) == (15840, 12240))
        // An unknown paper is taken as reported.
        let custom = PageSetup.letter.withPaper(CGSize(width: 500, height: 700), landscape: false)
        #expect((custom.width, custom.height) == (10000, 14000))
    }

    @Test func samePaperKeepsTheDocumentsExactTwips() {
        // Pages' 12240 × 14240 is 612 × 712 pt; OK in Page Setup without changes must not rewrite it.
        let pages = PageSetup(width: 12240, height: 14237, top: 1440, right: 1440, bottom: 1440, left: 1440)
        #expect(pages.withPaper(CGSize(width: 612, height: 712), landscape: false) == pages)
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
