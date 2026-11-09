import AppKit
import Foundation
import Testing

@testable import LibretillaDocx

@MainActor
@Suite struct FormattingTests {
    let codec = OOXMLCodec()

    struct Loaded {
        var doc: DocxDocument
        var bridge: AttributedStringBridge
        var text: NSMutableAttributedString
    }

    func load(_ name: String) throws -> Loaded {
        let doc = try codec.read(try Corpus.data(name))
        let bridge = AttributedStringBridge(doc)
        return Loaded(
            doc: doc, bridge: bridge,
            text: NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body)))
    }

    /// Saves and reopens; also checks the package is well formed.
    func save(_ l: Loaded) throws -> (DocxDocument, Data) {
        var out = l.doc
        out.styles = l.bridge.styles
        out.numbering = l.bridge.numbering
        out.body = l.bridge.body(from: l.text, base: l.doc.body).body
        let data = try codec.write(out)
        #expect(try PackageChecker.problems(data).isEmpty)
        return (try codec.read(data), data)
    }

    func range(of s: String, in text: NSAttributedString) throws -> NSRange {
        let r = (text.string as NSString).range(of: s)
        try #require(r.location != NSNotFound, "\(s) not found")
        return r
    }

    func paragraphs(_ doc: DocxDocument) -> [Paragraph] {
        doc.body.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
    }

    func paragraph(containing s: String, in doc: DocxDocument) throws -> Paragraph {
        try #require(paragraphs(doc).first { $0.text.contains(s) })
    }

    func xml(_ p: Paragraph) -> String { String(decoding: p.serialized(), as: UTF8.self) }

    // MARK: - Opening never changes anything

    @Test(arguments: Corpus.all)
    func reconcilingAndRenumberingAFreshDocumentChangesNothing(_ url: URL) throws {
        let doc = try codec.read(try Data(contentsOf: url))
        let bridge = AttributedStringBridge(doc)
        let text = NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body))
        let changedFormats = bridge.reconcile(text, range: NSRange(location: 0, length: text.length))
        let renumbered = bridge.renumber(text)
        #expect(!changedFormats, "reconcile changed \(url.lastPathComponent)")
        #expect(renumbered.isEmpty, "renumber changed \(url.lastPathComponent)")
        #expect(bridge.body(from: text, base: doc.body).body.serialized() == doc.package[doc.mainPartName])
    }

    // MARK: - Character formatting

    @Test func boldingAWordWritesOnlyThatRunAndParagraph() throws {
        var l = try load("01-plain.docx")
        l.bridge.apply(.bold(true), to: l.text, range: try range(of: "plain", in: l.text))
        let (back, _) = try save(l)
        let p = try paragraph(containing: "plain paragraph", in: back)
        #expect(xml(p).contains("<w:r><w:rPr><w:b/></w:rPr><w:t>plain</w:t></w:r>"))
        // Every other paragraph is byte-identical.
        let before = paragraphs(l.doc).filter { !$0.text.contains("plain paragraph") }.map(xml)
        let after = paragraphs(back).filter { !$0.text.contains("plain paragraph") }.map(xml)
        #expect(before == after)
        _ = l
    }

    @Test func unboldingABoldRunRemovesTheElementAndKeepsOtherProperties() throws {
        let l = try load("01-plain.docx")
        l.bridge.apply(.bold(false), to: l.text, range: try range(of: "bold", in: l.text))
        l.bridge.apply(.italic(true), to: l.text, range: try range(of: "Times New Roman 14 pt", in: l.text))
        let (back, _) = try save(l)
        let p = xml(try paragraph(containing: "bold", in: back))
        #expect(p.contains("<w:r><w:t>bold</w:t></w:r>") || p.contains("It has bold"))
        #expect(
            p.contains(
                "<w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:cs=\"Times New Roman\"/><w:i/><w:sz w:val=\"28\"/><w:szCs w:val=\"28\"/></w:rPr>"
            ))
    }

    @Test func unboldingHeadingTextSaysSoExplicitly() throws {
        let l = try load("02-headings.docx")
        let first = try #require(paragraphs(l.doc).first { $0.properties.styleId == "Heading1" })
        l.bridge.apply(.bold(false), to: l.text, range: try range(of: first.text, in: l.text))
        let (back, _) = try save(l)
        #expect(xml(try paragraph(containing: first.text, in: back)).contains("<w:b w:val=\"0\"/>"))
    }

    @Test func sizeFontColourHighlightAndScriptRoundTrip() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "plain", in: l.text)
        for change: RunChange in [
            .size(18), .font("Helvetica"), .color("1F4E79"), .highlight("green"), .verticalAlignment("superscript"),
            .underline(true), .strike(true),
        ] {
            l.bridge.apply(change, to: l.text, range: r)
        }
        let (back, _) = try save(l)
        let run = try #require(
            paragraphs(back).flatMap(\.inlines).compactMap { if case .run(let r) = $0 { r } else { nil } }
                .first { $0.text == "plain" })
        #expect(run.properties.size == 18)
        #expect(run.properties.font == "Helvetica")
        #expect(run.properties.color == "1F4E79")
        #expect(run.properties.highlight == "green")
        #expect(run.properties.verticalAlignment == "superscript")
        #expect(run.properties.underline == true)
        #expect(run.properties.strike == true)
        // Schema order: rFonts, strike, color, sz, szCs, highlight, u, vertAlign.
        let x = String(decoding: run.propertiesXML ?? Data(), as: UTF8.self)
        let order = ["w:rFonts", "w:strike", "w:color", "w:sz ", "w:szCs", "w:highlight", "w:u ", "w:vertAlign"]
        let positions = order.compactMap { x.range(of: "<" + $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted(), "\(x)")
    }

    @Test func clearFormattingRemovesDirectRunAndParagraphFormatting() throws {
        let l = try load("01-plain.docx")
        let all = NSRange(location: 0, length: l.text.length)
        l.bridge.apply(RunChange.clear, to: l.text, range: all)
        l.bridge.apply(ParagraphChange.clear, to: l.text, range: all)
        // Decorations that are now off are gone from the display too, so reconciling keeps them off.
        #expect(!l.bridge.reconcile(l.text, range: all))
        #expect(
            l.text.attribute(.underlineStyle, at: try range(of: "underlined", in: l.text).location, effectiveRange: nil)
                == nil)
        let (back, _) = try save(l)
        for p in paragraphs(back) {
            for case .run(let r) in p.inlines { #expect(r.propertiesXML == nil, "\(r.text)") }
            #expect(p.properties.alignment == nil && p.properties.indentLeft == nil && p.properties.spaceBefore == nil)
        }
        // The final section properties are untouched.
        #expect(back.body.suffix == l.doc.body.suffix)
    }

    // MARK: - Paragraph formatting

    @Test func alignmentWritesJcAndLeftRemovesIt() throws {
        let l = try load("01-plain.docx")
        l.bridge.apply(.alignment("center"), to: l.text, range: try range(of: "plain paragraph", in: l.text))
        l.bridge.apply(.alignment("left"), to: l.text, range: try range(of: "Centered paragraph", in: l.text))
        let (back, _) = try save(l)
        #expect(try paragraph(containing: "plain paragraph", in: back).properties.alignment == "center")
        #expect(xml(try paragraph(containing: "Centered paragraph", in: back)).hasPrefix("<w:p><w:r>"))
    }

    @Test func spacingAndIndentsKeepUnrelatedAttributes() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "Elit enim", in: l.text)
        l.bridge.apply(.lineSpacing(2), to: l.text, range: r)
        l.bridge.apply(.indent(by: 36), to: l.text, range: r)
        let (back, _) = try save(l)
        let p = xml(try paragraph(containing: "Elit enim", in: back))
        #expect(p.contains("<w:spacing w:before=\"240\" w:after=\"240\" w:line=\"480\" w:lineRule=\"auto\"/>"))
        #expect(p.contains("<w:ind w:left=\"720\"/>"))
        #expect(p.contains("<w:jc w:val=\"both\"/>"))
        // pPr children in schema order: spacing, ind, jc.
        let s = p.range(of: "<w:spacing")!.lowerBound
        let i = p.range(of: "<w:ind")!.lowerBound
        let j = p.range(of: "<w:jc")!.lowerBound
        #expect(s < i && i < j)
    }

    @Test func exactIndentsAndLineHeightsAreWrittenAndShown() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "Elit enim", in: l.text)
        l.bridge.apply(.indents(left: 54, right: 18, firstLine: -18), to: l.text, range: r)
        l.bridge.apply(.lineHeight(20, atLeast: false), to: l.text, range: r)
        let style = try #require(
            l.text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent == 54 && style.firstLineHeadIndent == 36 && style.tailIndent == -18)
        #expect(style.minimumLineHeight == 20 && style.maximumLineHeight == 20)
        var (back, _) = try save(l)
        var p = xml(try paragraph(containing: "Elit enim", in: back))
        #expect(p.contains("<w:ind w:left=\"1080\" w:right=\"360\" w:hanging=\"360\"/>"))
        #expect(p.contains("w:line=\"400\" w:lineRule=\"exact\""))

        // A first-line indent and "at least"; back to the style's own indents removes w:ind.
        l.bridge.apply(.indents(left: 0, right: 0, firstLine: 0), to: l.text, range: r)
        l.bridge.apply(.lineHeight(14, atLeast: true), to: l.text, range: r)
        (back, _) = try save(l)
        p = xml(try paragraph(containing: "Elit enim", in: back))
        #expect(!p.contains("<w:ind"))
        #expect(p.contains("w:line=\"280\" w:lineRule=\"atLeast\""))
        l.bridge.apply(.indents(left: 0, right: 0, firstLine: 36), to: l.text, range: r)
        (back, _) = try save(l)
        #expect(
            xml(try paragraph(containing: "Elit enim", in: back)).contains(
                "<w:ind w:left=\"0\" w:right=\"0\" w:firstLine=\"720\"/>"))
    }

    @Test func applyingAHeadingStyleWritesPStyleAndRedrawsTheText() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "plain paragraph", in: l.text)
        let before = try #require(l.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)
        let heading = try #require(l.bridge.styles.styleId(named: "heading 1"))
        l.bridge.apply(.style(heading), to: l.text, range: r)
        let after = try #require(l.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)
        #expect(after.pointSize > before.pointSize)
        let (back, _) = try save(l)
        #expect(try paragraph(containing: "plain paragraph", in: back).properties.styleId == heading)
    }

    @Test func typedTextInheritsTheFormatOfTheParagraph() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "plain paragraph", in: l.text)
        l.bridge.apply(.alignment("right"), to: l.text, range: r)
        // Enter at the end of the paragraph: the new paragraph shares the format.
        let end = NSMaxRange((l.text.string as NSString).paragraphRange(for: r)) - 1
        let attrs = l.text.attributes(at: end, effectiveRange: nil)
        l.text.insert(NSAttributedString(string: "\nNew line", attributes: attrs), at: end)
        let (back, _) = try save(l)
        #expect(try paragraph(containing: "New line", in: back).properties.alignment == "right")
    }

    // MARK: - Lists

    @Test func nestedListMarkersFollowWordNumbering() throws {
        let l = try load("03-nested-lists.docx")
        var markers: [String: ListMarker] = [:]
        var styles: [String: NSParagraphStyle] = [:]
        let ns = l.text.string as NSString
        for p in AttributedStringBridge.paragraphRanges(in: l.text, touching: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: p).trimmingCharacters(in: .newlines)
            if let m = AttributedStringBridge.listMarker(in: l.text, paragraph: p) { markers[key] = m }
            styles[key] = l.text.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle
        }
        #expect(markers["Fruit"]?.text == "•")
        #expect(markers["Apples"]?.text == "◦")
        #expect(markers["Granny Smith"]?.text == "▪")
        #expect(markers["Prepare"]?.text == "1.")
        #expect(markers.count >= 10)
        // Word's default list indents: the marker at the hanging indent, the text at the left indent (gap G4: no
        // NSTextList, which TextKit 2 would indent by depth instead).
        #expect(markers["Fruit"]?.x == 18 && markers["Fruit"]?.textStart == 36)
        #expect(markers["Apples"]?.x == 54 && markers["Apples"]?.textStart == 72)
        #expect(markers["Granny Smith"]?.x == 90 && markers["Granny Smith"]?.textStart == 108)
        #expect(styles["Apples"]?.headIndent == 72 && styles["Apples"]?.firstLineHeadIndent == 72)
        #expect(styles["Apples"]?.textLists.isEmpty == true)

        // An unusual indent shows exactly: the marker 70 pt in, the text at 100 pt, wrapped lines too.
        let fruit = try range(of: "Fruit", in: l.text)
        l.bridge.apply(.indents(left: 100, right: 0, firstLine: -30), to: l.text, range: fruit)
        let paragraph = ns.paragraphRange(for: fruit)
        let marker = try #require(AttributedStringBridge.listMarker(in: l.text, paragraph: paragraph))
        #expect(marker.text == "•" && marker.x == 70 && marker.textStart == 100)
        let style = l.text.attribute(.paragraphStyle, at: fruit.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == 100 && style?.firstLineHeadIndent == 100)
        // A marker wider than the hanging indent pushes the text to the next tab stop.
        let wide = AttributedStringBridge.listMarker(
            "10.10.10.",
            paragraph: {
                var p = ParagraphProperties(); p.indentLeft = 36; p.firstLine = -18; return p
            }(),
            font: .systemFont(ofSize: 12))
        #expect(wide.x == 18 && wide.textStart == 72)
        // The display reconciles to itself: nothing is written for the marker's text start.
        #expect(!l.bridge.reconcile(l.text, range: NSRange(location: 0, length: l.text.length)))
    }

    @Test func startingABulletListInADocumentWithoutNumberingCreatesThePart() throws {
        var l = try load("01-plain.docx")
        #expect(l.doc.numbering.xml == nil)
        var numbering = l.bridge.numbering
        let numId = numbering.addList(.bullet)
        l.bridge = AttributedStringBridge(styles: l.bridge.styles, numbering: numbering)
        let r = try range(of: "plain paragraph", in: l.text)
        l.bridge.apply(.list(numId: numId, level: 0), to: l.text, range: r)
        l.bridge.renumber(l.text)
        let style = l.text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(
            AttributedStringBridge.listMarker(
                in: l.text, paragraph: (l.text.string as NSString).paragraphRange(for: r))?.text == "•")
        #expect(style?.headIndent == 36)
        let (back, data) = try save(l)
        let p = try paragraph(containing: "plain paragraph", in: back)
        #expect(p.properties.numId == numId && p.properties.ilvl == 0)
        #expect(back.numbering.isBullet(numId: numId))
        let package = try OPCPackage(data: data)
        #expect(package["word/numbering.xml"] != nil)
        let rels = String(decoding: package["word/_rels/document.xml.rels"]!, as: UTF8.self)
        #expect(rels.contains("relationships/numbering"))
    }

    @Test func numberedListsRestartAndContinue() throws {
        let l = try load("01-plain.docx")
        var numbering = l.bridge.numbering
        let first = numbering.addList(.numbered)
        let second = numbering.addList(.numbered)
        let bridge = AttributedStringBridge(styles: l.bridge.styles, numbering: numbering)
        bridge.apply(.list(numId: first, level: 0), to: l.text, range: try range(of: "plain paragraph", in: l.text))
        bridge.apply(.list(numId: first, level: 0), to: l.text, range: try range(of: "A second", in: l.text))
        bridge.apply(.list(numId: second, level: 0), to: l.text, range: try range(of: "Centered", in: l.text))
        bridge.renumber(l.text)
        func marker(_ s: String) throws -> String? {
            let r = try range(of: s, in: l.text)
            return AttributedStringBridge.listMarker(
                in: l.text, paragraph: (l.text.string as NSString).paragraphRange(for: r))?.text
        }
        #expect(try marker("plain paragraph") == "1.")
        #expect(try marker("A second") == "2.")
        #expect(try marker("Centered") == "1.")
    }

    @Test func listLevelsAndRemoval() throws {
        let l = try load("03-nested-lists.docx")
        let r = try range(of: "Pears", in: l.text)
        l.bridge.apply(.listLevel(by: 1), to: l.text, range: r)
        l.bridge.apply(.list(numId: nil, level: 0), to: l.text, range: try range(of: "Carrots", in: l.text))
        l.bridge.renumber(l.text)
        let (back, _) = try save(l)
        #expect(try paragraph(containing: "Pears", in: back).properties.ilvl == 2)
        let carrots = try paragraph(containing: "Carrots", in: back)
        #expect(!carrots.properties.hasNumbering)
        #expect(!xml(carrots).contains("ListParagraph"))
    }

    // MARK: - AppKit changes the display; reconcile updates the semantics

    @Test func fontPanelStyleChangesAreReconciled() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "plain", in: l.text)
        let font = try #require(NSFont(name: "Helvetica-Bold", size: 20))
        l.text.addAttribute(.font, value: font, range: r)
        l.text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        l.text.addAttribute(.foregroundColor, value: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), range: r)
        #expect(l.bridge.reconcile(l.text, range: r))
        #expect(!l.bridge.reconcile(l.text, range: r), "reconcile is idempotent")
        let (back, _) = try save(l)
        let p = xml(try paragraph(containing: "plain paragraph", in: back))
        #expect(p.contains("w:ascii=\"Helvetica\""))
        #expect(p.contains("<w:b/>"))
        #expect(p.contains("<w:sz w:val=\"40\"/>"))
        #expect(p.contains("<w:color w:val=\"FF0000\"/>"))
        #expect(p.contains("<w:u w:val=\"single\"/>"))
    }

    @Test func rulerIndentChangesAreReconciled() throws {
        let l = try load("01-plain.docx")
        let r = (l.text.string as NSString).paragraphRange(for: try range(of: "plain paragraph", in: l.text))
        let style =
            (l.text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as! NSParagraphStyle)
            .mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = 54
        style.firstLineHeadIndent = 72
        style.tabStops = [NSTextTab(textAlignment: .center, location: 144)]
        l.text.addAttribute(.paragraphStyle, value: style, range: r)
        #expect(l.bridge.reconcile(l.text, range: r))
        let (back, _) = try save(l)
        let p = xml(try paragraph(containing: "plain paragraph", in: back))
        #expect(p.contains("<w:ind w:left=\"1080\" w:right=\"0\" w:firstLine=\"360\"/>"), "\(p)")
        #expect(p.contains("<w:tabs><w:tab w:val=\"center\" w:pos=\"2880\"/></w:tabs>"))
    }

    @Test func pastedTextGetsFormatsFromItsDisplay() throws {
        let l = try load("01-plain.docx")
        let at = try range(of: "This is a plain paragraph", in: l.text).location
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let pasted = NSAttributedString(
            string: "Pasted\n",
            attributes: [.font: NSFont(name: "Courier", size: 12)!, .paragraphStyle: style])
        l.text.insert(pasted, at: at)
        l.bridge.reconcile(l.text, range: NSRange(location: at, length: pasted.length))
        let (back, _) = try save(l)
        let p = try paragraph(containing: "Pasted", in: back)
        #expect(p.properties.alignment == "center")
        let run = try #require(p.inlines.compactMap { if case .run(let r) = $0 { r } else { nil } }.first)
        #expect(run.properties.font == "Courier" && run.properties.size == 12)
        // The paragraph it was pasted before is untouched.
        #expect(
            xml(try paragraph(containing: "plain paragraph", in: back))
                == xml(try paragraph(containing: "plain paragraph", in: l.doc)))
    }

    @Test func superscriptAndSubscriptAreDrawnSmallerButKeepTheirSize() throws {
        let l = try load("01-plain.docx")
        let r = try range(of: "plain", in: l.text)
        let full = try #require(l.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont).pointSize
        l.bridge.apply(.verticalAlignment("superscript"), to: l.text, range: r)
        let shown = try #require(l.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)
        #expect(abs(shown.pointSize - full * 2 / 3) < 0.01)
        #expect(l.text.attribute(.superscript, at: r.location, effectiveRange: nil) as? Int == 1)
        // The format bar shows the run's size, not the drawn one.
        let format = l.bridge.selectionFormat(l.text, range: r, typingAttributes: [:])
        #expect(format.fontSize == Double(full))
        // Redrawn text reconciles to itself: no size is written.
        #expect(!l.bridge.reconcile(l.text, range: r))
        var (back, _) = try save(l)
        var run = try #require(
            paragraphs(back).flatMap(\.inlines).compactMap { if case .run(let r) = $0 { r } else { nil } }
                .first { $0.text == "plain" })
        #expect(run.properties.size == nil && run.properties.verticalAlignment == "superscript")

        // AppKit's Font ▸ Baseline ▸ Use Default removes the script but leaves the smaller font: back to full size.
        l.text.removeAttribute(.superscript, range: r)
        #expect(l.bridge.reconcile(l.text, range: r))
        (back, _) = try save(l)
        run = try #require(
            paragraphs(back).flatMap(\.inlines).compactMap { if case .run(let r) = $0 { r } else { nil } }
                .first { $0.text.contains("plain") }, "merged back into its neighbours")
        #expect(run.properties.size == nil && run.properties.verticalAlignment == nil)

        // Pasted subscript text, drawn small: a subscript of the paragraph's size.
        let at = try range(of: "This is a plain paragraph", in: l.text).location
        let font = try #require(NSFont(name: "Courier", size: 8))
        l.text.insert(NSAttributedString(string: "2", attributes: [.font: font, .superscript: -1]), at: at)
        l.bridge.reconcile(l.text, range: NSRange(location: at, length: 1))
        let pasted = try #require(l.text.attribute(.libretillaRun, at: at, effectiveRange: nil) as? RunFormat)
        #expect(pasted.properties.verticalAlignment == "subscript")
        #expect(pasted.properties.size == 8, "a size that isn't the run's own scaled is a size")
    }

    @Test func substitutedFontsForEmojiAreNotWritten() throws {
        let l = try load("01-plain.docx")
        let at = try range(of: "plain paragraph", in: l.text).location
        var attrs = l.text.attributes(at: at, effectiveRange: nil)
        attrs[.font] = NSFont(name: "Apple Color Emoji", size: 11)
        l.text.insert(NSAttributedString(string: "🙂", attributes: attrs), at: at)
        l.bridge.reconcile(l.text, range: NSRange(location: at, length: 2))
        let (back, _) = try save(l)
        #expect(!xml(try paragraph(containing: "plain paragraph", in: back)).contains("Emoji"))
    }

    // MARK: - Styles

    @Test func missingStylesAreCopiedFromTheTemplate() throws {
        let blank = try codec.read(try Data(contentsOf: Corpus.root.appendingPathComponent("Resources/Blank.docx")))
        var styles = try load("12-pages.docx").doc.styles
        #expect(styles.styleId(named: "heading 3") == nil)
        let ensured = styles.ensureStyle("Heading3", from: blank.styles)
        let id = try #require(ensured)
        #expect(styles.styleId(named: "heading 3") == id)
        let (_, run) = styles.resolveParagraphStyle(id)
        #expect(run.bold == true)
        // Existing styles keep their bytes.
        let before = String(decoding: try load("12-pages.docx").doc.styles.stylesXML!, as: UTF8.self)
        let after = String(decoding: styles.stylesXML!, as: UTF8.self)
        #expect(after.hasPrefix(String(before.prefix(before.count - "</w:styles>".count))))
    }

    @Test func updatingAStyleRewritesOnlyThatStyle() throws {
        let l = try load("02-headings.docx")
        var styles = l.doc.styles
        var run = RunProperties()
        run.color = "C00000"
        var paragraph = ParagraphProperties()
        paragraph.alignment = "center"
        styles.updateStyle(
            "Heading2", paragraph: paragraph, paragraphFields: [.alignment], run: run, runFields: [.color])
        let (p, r) = styles.resolveParagraphStyle("Heading2")
        #expect(r.color == "C00000" && p.alignment == "center")
        #expect(r.bold == true, "other properties of the style are kept")
        let old = try #require(l.doc.styles.styleElement("Heading1"))
        #expect(styles.styleElement("Heading1") == old)
    }
}

@Suite struct ElementPatchTests {
    let order = ElementPatch.runPropertiesOrder

    func patch(_ xml: String?, _ edits: [ElementPatch.Edit]) -> String? {
        ElementPatch.apply(edits, to: xml.map { Data($0.utf8) }, wrapper: "w:rPr", order: order).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    @Test func insertsInSchemaOrderAndKeepsUnknownChildren() {
        let out = patch(
            "<w:rPr><w:rFonts w:ascii=\"A\"/><w14:glow w14:rad=\"1\"/><w:sz w:val=\"20\"/></w:rPr>",
            [.replace("w:b", xml: "<w:b/>"), .replace("w:u", xml: "<w:u w:val=\"single\"/>")])
        #expect(
            out
                == "<w:rPr><w:rFonts w:ascii=\"A\"/><w:b/><w14:glow w14:rad=\"1\"/><w:sz w:val=\"20\"/><w:u w:val=\"single\"/></w:rPr>"
        )
    }

    @Test func attributeEditsKeepOtherAttributes() {
        let out = patch(
            "<w:rPr><w:rFonts w:ascii=\"A\" w:eastAsia=\"MS Mincho\" w:asciiTheme=\"minorHAnsi\"/></w:rPr>",
            [.attributes("w:rFonts", [("w:ascii", "B"), ("w:asciiTheme", nil), ("w:hAnsi", "B")])])
        #expect(out == "<w:rPr><w:rFonts w:ascii=\"B\" w:eastAsia=\"MS Mincho\" w:hAnsi=\"B\"/></w:rPr>")
    }

    @Test func removingTheLastChildRemovesTheElement() {
        #expect(patch("<w:rPr><w:b/></w:rPr>", [.remove("w:b")]) == nil)
        #expect(patch(nil, [.remove("w:b")]) == nil)
        #expect(patch("<w:rPr/>", [.replace("w:i", xml: "<w:i/>")]) == "<w:rPr><w:i/></w:rPr>")
    }
}
