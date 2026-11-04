import Testing
@testable import CartillaDocx

@Suite struct DocxDocumentTests {
    @Test func plainTextJoinsParagraphs() {
        let doc = DocxDocument(blocks: [
            .paragraph(Paragraph(runs: [Run(text: "Hola, "), Run(text: "mundo", bold: true)])),
            .pageBreak,
            .paragraph(Paragraph(styleId: "Heading1", runs: [Run(text: "Título")])),
        ])
        #expect(doc.plainText == "Hola, mundo\nTítulo")
    }

    @Test func defaultSectionIsUSLetter() {
        let section = SectionProperties()
        #expect(section.pageWidthTwips == 12240)
        #expect(section.pageHeightTwips == 15840)
    }
}
