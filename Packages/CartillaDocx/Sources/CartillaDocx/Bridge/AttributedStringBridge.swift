import AppKit

/// Converts a `DocumentBody` to an `NSAttributedString` for TextKit 2 and back (bootstrap §5.2).
///
/// - Every paragraph, including the last, ends with `\n`.
/// - Tables and other unmodelled body blocks show as one placeholder attachment paragraph.
/// - The final `w:sectPr` and hidden body-level markers aren't shown; they're re-emitted on save.
/// - A paragraph whose text and custom attributes are unchanged is written back from its original
///   bytes. Only edited paragraphs are re-serialized.
public struct AttributedStringBridge: Sendable {
    public let styles: StyleSheet
    public let numbering: Numbering
    /// External link targets by relationship id, for showing links.
    public let hyperlinkTargets: [String: String]
    /// Embedded image bytes by relationship id, for showing pictures.
    public let images: [String: Data]
    /// The text column width in points (tables wider than this are drawn scaled to fit).
    public let textWidth: CGFloat

    public init(
        styles: StyleSheet, numbering: Numbering = Numbering(), hyperlinkTargets: [String: String] = [:],
        images: [String: Data] = [:], textWidth: CGFloat = PageSetup.fallback.textWidth
    ) {
        self.styles = styles
        self.numbering = numbering
        self.hyperlinkTargets = hyperlinkTargets
        self.images = images
        self.textWidth = textWidth
    }

    public init(_ document: DocxDocument) {
        self.init(
            styles: document.styles, numbering: document.numbering, hyperlinkTargets: document.hyperlinkTargets,
            images: document.images, textWidth: document.body.pageSetup.textWidth)
    }

    /// Where `link` points: its new target, its relationship's URL, or nil (bookmark links).
    public func url(of link: Hyperlink) -> URL? {
        if let target = link.newTarget { return URL(string: target) }
        return link.relationshipId.flatMap { hyperlinkTargets[$0] }.flatMap(URL.init(string:))
    }

    // MARK: - Model → text

    public func attributedString(for body: DocumentBody) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var pendingHidden: [OpaqueBlock] = []
        var counter = Numbering.Counter(numbering)
        for block in body.blocks {
            switch block {
            case .paragraph(let p):
                out.append(paragraphText(p, leadingBlocks: pendingHidden, counter: &counter))
                pendingHidden = []
            case .opaque(let o) where Self.isHidden(o):
                pendingHidden.append(o)
            case .opaque(let o):
                out.append(blockText(o, leadingBlocks: pendingHidden))
                pendingHidden = []
            }
        }
        return out
    }

    /// Body-level items that take no space: the section properties and markers like bookmarks.
    static func isHidden(_ block: OpaqueBlock) -> Bool {
        block.isSectionProperties || (block.visibleText.isEmpty && block.kind != "w:tbl" && block.kind != "w:sdt")
    }

    func paragraphText(_ p: Paragraph, leadingBlocks: [OpaqueBlock], counter: inout Numbering.Counter)
        -> NSAttributedString
    {
        let effective = effectiveParagraph(p.properties)
        let marker = effective.hasNumbering ? counter.next(numId: effective.numId!, ilvl: effective.ilvl ?? 0) : nil
        let paragraphStyle = Self.paragraphStyle(effective, marker: marker)
        let format = ParagraphFormat(properties: p.properties, xml: p.propertiesXML)
        let text = NSMutableAttributedString()
        var pendingMarkers: [OpaqueInline] = []

        func append(_ string: String, _ attrs: [NSAttributedString.Key: Any]) {
            guard !string.isEmpty else { return }
            var attrs = attrs
            attrs[.paragraphStyle] = paragraphStyle
            if !pendingMarkers.isEmpty {
                let first = NSMutableAttributedString(string: String(string.prefix(1)), attributes: attrs)
                first.addAttribute(.cartillaMarkers, value: MarkerBox(pendingMarkers), range: NSRange(0..<first.length))
                pendingMarkers = []
                text.append(first)
                text.append(NSAttributedString(string: String(string.dropFirst()), attributes: attrs))
            } else {
                text.append(NSAttributedString(string: string, attributes: attrs))
            }
        }

        func appendRun(_ r: Run, extra: [NSAttributedString.Key: Any] = [:]) {
            var attrs = characterAttributes(
                styles.resolveRun(paragraphStyle: p.properties.styleId, direct: r.properties))
            attrs[.cartillaRun] = RunFormat(properties: r.properties, xml: r.propertiesXML)
            attrs.merge(extra) { _, new in new }
            // Page breaks show as a chip (an object character); the rest of the run as text.
            for (i, piece) in r.text.split(separator: Run.pageBreak, omittingEmptySubsequences: false).enumerated() {
                if i > 0 { append(Self.pageBreakCharacter, Self.pageBreakAttributes(attrs)) }
                append(String(piece), attrs)
            }
        }

        for inline in p.inlines {
            switch inline {
            case .run(let r):
                appendRun(r)
            case .hyperlink(let link):
                let box = HyperlinkBox(link, url: url(of: link))
                var extra: [NSAttributedString.Key: Any] = [.cartillaHyperlink: box]
                if let url = box.url { extra[.link] = url }
                for r in link.runs { appendRun(r, extra: extra) }
            case .opaque(let o):
                let resolved = styles.resolveRun(paragraphStyle: p.properties.styleId, direct: o.displayProperties)
                var attrs = characterAttributes(resolved)
                attrs[.cartillaOpaque] = OpaqueInlineBox(o)
                switch o.display {
                case .invisible:
                    pendingMarkers.append(o)
                case .text(let t):
                    if o.isHyperlink {
                        attrs[.foregroundColor] = NSColor.linkColor
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    append(t, attrs)
                case .object(let label):
                    attrs[.attachment] =
                        pictureAttachment(o) ?? Self.placeholderAttachment(label, font: attrs[.font] as? NSFont)
                    append("\u{FFFC}", attrs)
                }
            }
        }

        // Paragraph terminator: carries the paragraph's style; font from the paragraph style.
        var terminator = characterAttributes(
            styles.resolveRun(paragraphStyle: p.properties.styleId, direct: RunProperties()))
        terminator[.paragraphStyle] = paragraphStyle
        let contentLength = text.length
        let origin = ParagraphOrigin(
            paragraph: p, leadingBlocks: leadingBlocks, trailingMarkers: pendingMarkers, format: format,
            text: text.string, signature: Span.signature(of: text, in: NSRange(location: 0, length: contentLength)))
        text.append(NSAttributedString(string: "\n", attributes: terminator))
        let all = NSRange(location: 0, length: text.length)
        text.addAttribute(.cartillaParagraph, value: origin, range: all)
        text.addAttribute(.cartillaParagraphFormat, value: format, range: all)
        return text
    }

    func blockText(_ o: OpaqueBlock, leadingBlocks: [OpaqueBlock]) -> NSAttributedString {
        if let table = tableText(o, leadingBlocks: leadingBlocks) { return table }
        var label = o.summary
        let preview = o.visibleText.replacingOccurrences(of: "\n", with: " · ").trimmingCharacters(in: .whitespaces)
        if !preview.isEmpty { label += ": " + String(preview.prefix(80)) + (preview.count > 80 ? "…" : "") }
        let (_, run) = styles.resolveParagraphStyle(nil)
        var attrs = characterAttributes(run)
        attrs[.attachment] = Self.placeholderAttachment(label, font: attrs[.font] as? NSFont)
        attrs[.cartillaBlock] = OpaqueBlockBox(o, leadingBlocks: leadingBlocks)
        let text = NSMutableAttributedString(string: "\u{FFFC}", attributes: attrs)
        attrs[.attachment] = nil
        attrs[.cartillaBlock] = nil
        text.append(NSAttributedString(string: "\n", attributes: attrs))
        return text
    }

    // MARK: - Text → model

    public struct Result: Sendable {
        public var body: DocumentBody
        /// Content that couldn't be kept exactly (for a non-blocking notice).
        public var notices: [String]
    }

    /// Rebuilds the document body from edited text. `base` supplies the part's prefix/suffix and
    /// the hidden trailing items (final section properties).
    public func body(from text: NSAttributedString, base: DocumentBody) -> Result {
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        var start = 0
        while start < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: start, length: 0))
            paragraphs.append(r)
            start = NSMaxRange(r)
        }

        // Which ranges are the first / last occurrence of each origin (Enter splits a paragraph).
        var firstIndex: [ObjectIdentifier: Int] = [:]
        var lastIndex: [ObjectIdentifier: Int] = [:]
        for (i, r) in paragraphs.enumerated() {
            guard let o = text.attribute(.cartillaParagraph, at: r.location, effectiveRange: nil) as? ParagraphOrigin
            else { continue }
            let id = ObjectIdentifier(o)
            if firstIndex[id] == nil { firstIndex[id] = i }
            lastIndex[id] = i
        }

        var blocks: [Block] = []
        var notices: [String] = []
        var emittedOpaque = Set<ObjectIdentifier>()
        var emittedBlocks = Set<ObjectIdentifier>()

        for (i, full) in paragraphs.enumerated() {
            let content = Self.contentRange(full, in: ns)
            let origin = text.attribute(.cartillaParagraph, at: full.location, effectiveRange: nil) as? ParagraphOrigin
            let isFirst = origin.map { firstIndex[ObjectIdentifier($0)] == i } ?? false
            let isLast = origin.map { lastIndex[ObjectIdentifier($0)] == i } ?? true

            // Paragraphs holding opaque blocks (tables, content controls): emit each block once, and any
            // text around them as plain paragraphs, so a block is never lost to surrounding edits.
            var blockChars: [(Int, OpaqueBlockBox)] = []
            text.enumerateAttribute(.cartillaBlock, in: content) { v, r, _ in
                if let box = v as? OpaqueBlockBox { blockChars.append((r.location, box)) }
            }
            if !blockChars.isEmpty {
                var cursor = content.location
                for (at, box) in blockChars {
                    if at > cursor {
                        blocks.append(
                            .paragraph(
                                editedParagraph(
                                    text, NSRange(location: cursor, length: at - cursor), origin: nil, format: nil,
                                    keepSectionBreak: true, emitted: &emittedOpaque, notices: &notices)))
                    }
                    if emittedBlocks.insert(ObjectIdentifier(box)).inserted {
                        blocks += box.leadingBlocks.map(Block.opaque)
                        blocks.append(.opaque(box.block))
                    }
                    cursor = at + 1
                }
                if cursor < NSMaxRange(content) {
                    blocks.append(
                        .paragraph(
                            editedParagraph(
                                text, NSRange(location: cursor, length: NSMaxRange(content) - cursor), origin: nil,
                                format: nil, keepSectionBreak: true, emitted: &emittedOpaque, notices: &notices)))
                }
                continue
            }

            if let origin, isFirst { blocks += origin.leadingBlocks.map(Block.opaque) }

            if let origin, isFirst, isLast, Self.paragraphFormat(text, full) === origin.format,
                text.attributedSubstring(from: content).string == origin.text,
                Span.signature(of: text, in: content) == origin.signature
            {
                blocks.append(.paragraph(origin.paragraph))
                Self.markEmitted(origin.paragraph, text, content, into: &emittedOpaque)
                continue
            }

            var p = editedParagraph(
                text, content, origin: origin, format: Self.paragraphFormat(text, full), keepSectionBreak: isLast,
                emitted: &emittedOpaque, notices: &notices)
            if let origin, isLast {
                p.inlines += origin.trailingMarkers.map(Inline.opaque)
            }
            blocks.append(.paragraph(p))
        }

        // Hidden items after the last visible block (the final w:sectPr, trailing bookmarks).
        var tail: [Block] = []
        for block in base.blocks.reversed() {
            guard case .opaque(let o) = block, Self.isHidden(o) else { break }
            tail.insert(block, at: 0)
        }
        // Word expects at least one paragraph in the body.
        if !blocks.contains(where: { if case .paragraph = $0 { true } else { false } }) {
            blocks.append(.paragraph(Paragraph()))
        }
        var body = base
        body.blocks = blocks + tail
        return Result(body: body, notices: notices)
    }

    static func contentRange(_ paragraph: NSRange, in ns: NSString) -> NSRange {
        var r = paragraph
        while r.length > 0 {
            let c = ns.character(at: NSMaxRange(r) - 1)
            guard c == 0x0A || c == 0x0D || c == 0x2029 else { break }
            r.length -= 1
        }
        return r
    }

    static func markEmitted(
        _ p: Paragraph, _ text: NSAttributedString, _ range: NSRange,
        into set: inout Set<ObjectIdentifier>
    ) {
        text.enumerateAttribute(.cartillaOpaque, in: range) { v, _, _ in
            if let v = v as AnyObject? { set.insert(ObjectIdentifier(v)) }
        }
    }

    /// The paragraph's format: its first character's, else its terminator's (pasted text may lack one).
    static func paragraphFormat(_ text: NSAttributedString, _ paragraph: NSRange) -> ParagraphFormat? {
        guard paragraph.length > 0 else { return nil }
        return text.attribute(.cartillaParagraphFormat, at: paragraph.location, effectiveRange: nil) as? ParagraphFormat
            ?? text.attribute(.cartillaParagraphFormat, at: NSMaxRange(paragraph) - 1, effectiveRange: nil)
            as? ParagraphFormat
    }

    func editedParagraph(
        _ text: NSAttributedString, _ range: NSRange, origin: ParagraphOrigin?, format: ParagraphFormat?,
        keepSectionBreak: Bool, emitted: inout Set<ObjectIdentifier>, notices: inout [String]
    ) -> Paragraph {
        var p = origin?.paragraph.edited() ?? Paragraph()
        p.propertiesXMLWithoutSectionBreak = nil
        if let format {
            p.properties = format.properties
            p.propertiesXML = keepSectionBreak ? format.xml : format.xmlWithoutSectionBreak
            if !keepSectionBreak { p.properties.hasSectionBreak = false }
        } else if origin != nil {
            // Reached only for text around an opaque block: plain paragraph.
            p.properties = ParagraphProperties()
            p.propertiesXML = nil
        }
        var inlines: [Inline] = []
        // The box of each `.hyperlink` in `inlines`, in order.
        var linkBoxes: [HyperlinkBox] = []
        let ns = text.string as NSString

        text.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            if let markers = attrs[.cartillaMarkers] as? MarkerBox, emitted.insert(ObjectIdentifier(markers)).inserted {
                inlines += markers.markers.map(Inline.opaque)
            }
            let string = ns.substring(with: r)
            if let box = attrs[.cartillaOpaque] as? OpaqueInlineBox {
                // Emit the opaque item once, when its whole visible text is still there unchanged.
                let id = ObjectIdentifier(box)
                if emitted.contains(id) { return }
                var whole = NSRange()
                _ = text.attribute(.cartillaOpaque, at: r.location, longestEffectiveRange: &whole, in: range)
                if ns.substring(with: whole) == box.inline.visibleText {
                    emitted.insert(id)
                    inlines.append(.opaque(box.inline))
                } else if NSEqualRanges(whole, r) || r.location == whole.location {
                    emitted.insert(id)
                    let kept = ns.substring(with: whole).replacingOccurrences(of: "\u{FFFC}", with: "")
                    if !kept.isEmpty {
                        inlines.append(
                            .run(
                                Run(
                                    text: kept, properties: box.inline.displayProperties,
                                    propertiesXML: box.inline.displayProperties.xml())))
                    }
                    notices.append("Part of a \(Self.describe(box.inline.kind)) was edited and kept as plain text.")
                }
                return
            }
            // An attachment that isn't the document's own (Insert ▸ Image…, paste, drop) is a new picture.
            if let attachment = attrs[.attachment] as? NSTextAttachment, attrs[.cartillaPageBreak] == nil {
                for _ in 0..<string.utf16.count {
                    if let picture = Self.newPicture(from: attachment, runFormat: attrs[.cartillaRun] as? RunFormat) {
                        inlines.append(.opaque(picture))
                    } else {
                        notices.append("An inserted image couldn't be read and wasn't saved.")
                    }
                }
                return
            }
            let plain =
                attrs[.cartillaPageBreak] != nil
                ? String(repeating: Run.pageBreak, count: string.utf16.count)
                : string.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !plain.isEmpty else { return }
            let run: Run
            if let format = attrs[.cartillaRun] as? RunFormat {
                run = Run(text: plain, properties: format.properties, propertiesXML: format.xml)
            } else {
                let props = Self.runProperties(fromDisplay: attrs)
                run = Run(text: plain, properties: props, propertiesXML: props.xml())
            }
            if let box = attrs[.cartillaHyperlink] as? HyperlinkBox {
                // Consecutive text of one link is one w:hyperlink; its runs are compared on the way out.
                if case .hyperlink(var link) = inlines.last, linkBoxes.last.map({ $0 === box }) == true {
                    var runs = [Inline.run(link.runs.last!)]
                    link.runs.removeLast()
                    Self.appendRun(&runs, run)
                    link.runs += runs.compactMap { if case .run(let r) = $0 { r } else { nil } }
                    inlines[inlines.count - 1] = .hyperlink(link)
                } else {
                    var link = box.link
                    link.runs = [run]
                    inlines.append(.hyperlink(link))
                    linkBoxes.append(box)
                }
            } else {
                Self.appendRun(&inlines, run)
            }
        }
        // A link whose runs didn't change keeps its source bytes.
        var k = 0
        for (i, inline) in inlines.enumerated() {
            guard case .hyperlink(let link) = inline else { continue }
            inlines[i] = .hyperlink(linkBoxes[k].link.with(runs: link.runs))
            k += 1
        }
        p.inlines = inlines
        return p
    }

    /// Merges adjacent runs with identical formatting (display attributes split attribute runs).
    static func appendRun(_ inlines: inout [Inline], _ run: Run) {
        if case .run(var last) = inlines.last, last.propertiesXML == run.propertiesXML,
            last.properties == run.properties
        {
            last.text += run.text
            inlines[inlines.count - 1] = .run(last)
        } else {
            inlines.append(.run(run))
        }
    }

    static func describe(_ kind: String) -> String {
        switch kind {
        case "w:hyperlink": "link"
        case "w:fldSimple": "field"
        case "w:sdt": "content control"
        case "w:ins": "tracked insertion"
        case "w:smartTag", "w:customXml": "tagged text"
        default: "\(kind) element"
        }
    }

    /// Formatting for text that has no source run (pasted or typed into an empty paragraph).
    static func runProperties(fromDisplay attrs: [NSAttributedString.Key: Any]) -> RunProperties {
        var r = RunProperties()
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { r.bold = true }
            if traits.contains(.italicFontMask) { r.italic = true }
        }
        if let u = attrs[.underlineStyle] as? Int, u != 0 { r.underline = true }
        if let s = attrs[.strikethroughStyle] as? Int, s != 0 { r.strike = true }
        return r
    }
}

// MARK: - Display attributes

extension AttributedStringBridge {
    /// Word's default when a document specifies no size.
    static let defaultFontSize: CGFloat = 10

    func characterAttributes(_ run: RunProperties) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        let size = CGFloat(run.size ?? Double(Self.defaultFontSize))
        var font =
            styles.fontFamily(for: run).flatMap { Self.font(family: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        let manager = NSFontManager.shared
        if run.bold == true { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic == true { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        attrs[.font] = font
        if let hex = run.color, hex != "auto", let color = Self.color(hex: hex) {
            attrs[.foregroundColor] = color
        } else {
            attrs[.foregroundColor] = NSColor.textColor
        }
        if run.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        switch run.verticalAlignment {
        case "superscript": attrs[.superscript] = 1
        case "subscript": attrs[.superscript] = -1
        default: break
        }
        if let h = run.highlight, let color = Self.highlightColors[h] { attrs[.backgroundColor] = color }
        return attrs
    }

    static func font(family: String, size: CGFloat) -> NSFont? {
        NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// How Cartilla shows a Word highlight colour (e.g. `yellow`).
    public static func highlightColor(_ name: String) -> NSColor? { highlightColors[name] }

    static let highlightColors: [String: NSColor] = [
        "yellow": .systemYellow.withAlphaComponent(0.5), "green": .systemGreen.withAlphaComponent(0.4),
        "cyan": .cyan.withAlphaComponent(0.4), "magenta": .magenta.withAlphaComponent(0.4),
        "blue": .systemBlue.withAlphaComponent(0.4), "red": .systemRed.withAlphaComponent(0.4),
        "darkBlue": .blue.withAlphaComponent(0.5), "darkCyan": .systemTeal.withAlphaComponent(0.5),
        "darkGreen": .systemGreen.withAlphaComponent(0.6), "darkMagenta": .purple.withAlphaComponent(0.5),
        "darkRed": .red.withAlphaComponent(0.6), "darkYellow": .systemOrange.withAlphaComponent(0.5),
        "darkGray": .darkGray.withAlphaComponent(0.5), "lightGray": .lightGray.withAlphaComponent(0.5),
        "black": .black.withAlphaComponent(0.6),
    ]

    /// Paragraph properties as displayed: direct formatting over the list level over the style chain.
    public func effectiveParagraph(_ direct: ParagraphProperties) -> ParagraphProperties {
        let (styleProps, _) = styles.resolveParagraphStyle(direct.styleId)
        var base = styleProps
        let merged = direct.over(base)
        if merged.hasNumbering, let level = numbering.level(numId: merged.numId!, ilvl: merged.ilvl ?? 0) {
            if let left = level.indentLeft { base.indentLeft = left }
            if let first = level.firstLine { base.firstLine = first }
            return direct.over(base)
        }
        return merged
    }

    /// TextKit 2 lays out list items itself: it ignores the paragraph's indents and indents by
    /// nesting depth (`textLists.count`), half an inch per level, the same as Word's default lists.
    /// So the depth is the list indent in half inches (gap G4 in docs/TEXTKIT2_GAPS.md). Only the
    /// innermost list's marker is drawn; it's the literal marker text Word would show.
    static func textLists(marker: String, indent: Double?) -> [NSTextList] {
        let depth = min(9, max(1, Int(((indent ?? 36) / 36).rounded())))
        let parents = (1..<depth).map { _ in NSTextList(markerFormat: NSTextList.MarkerFormat(""), options: 0) }
        return parents + [NSTextList(markerFormat: NSTextList.MarkerFormat(marker), options: 0)]
    }

    /// The marker a paragraph style shows, and its list depth.
    static func listMarker(_ style: NSParagraphStyle?) -> (marker: String, depth: Int)? {
        guard let style, let last = style.textLists.last else { return nil }
        return (last.markerFormat.rawValue, style.textLists.count)
    }

    /// Default tab stops every half inch, as in Word's `w:defaultTabStop` default.
    static let defaultTabInterval: CGFloat = 36

    static func paragraphStyle(_ p: ParagraphProperties, marker: String? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = (p.tabs ?? []).map { tab in
            let alignment: NSTextAlignment =
                switch tab.alignment {
                case "center": .center
                case "right": .right
                case "decimal": .right
                default: .left
                }
            var options: [NSTextTab.OptionKey: Any] = [:]
            if tab.alignment == "decimal" { options[.columnTerminators] = NSTextTab.columnTerminators(for: .current) }
            return NSTextTab(textAlignment: alignment, location: CGFloat(tab.position), options: options)
        }
        style.defaultTabInterval = defaultTabInterval
        if let marker { style.textLists = textLists(marker: marker, indent: p.indentLeft) }
        switch p.alignment {
        case "center": style.alignment = .center
        case "right", "end": style.alignment = .right
        case "both", "distribute": style.alignment = .justified
        default: style.alignment = .natural
        }
        let left = CGFloat(p.indentLeft ?? 0)
        style.headIndent = left
        style.firstLineHeadIndent = max(0, left + CGFloat(p.firstLine ?? 0))
        if let right = p.indentRight, right > 0 { style.tailIndent = -CGFloat(right) }
        style.paragraphSpacingBefore = CGFloat(p.spaceBefore ?? 0)
        style.paragraphSpacing = CGFloat(p.spaceAfter ?? 0)
        if let line = p.line {
            switch p.lineRule ?? "auto" {
            case "exact":
                style.minimumLineHeight = CGFloat(line)
                style.maximumLineHeight = CGFloat(line)
            case "atLeast": style.minimumLineHeight = CGFloat(line)
            default: style.lineHeightMultiple = CGFloat(line)
            }
        }
        return style
    }

    // MARK: Page breaks

    static let pageBreakCharacter = "\u{FFFC}"

    /// `run`'s attributes on a page break: its chip, marked so saving writes `<w:br w:type="page"/>`.
    public static func pageBreakAttributes(_ run: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = run
        attrs[.attachment] = placeholderAttachment("Page break", font: run[.font] as? NSFont)
        attrs[.cartillaPageBreak] = true
        return attrs
    }

    /// A page break to insert at the caret, with the formatting the caret would type with.
    public static func pageBreak(typingAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attrs = typingAttributes
        for key in NSAttributedString.Key.cartillaNonInheritable { attrs[key] = nil }
        return NSAttributedString(string: pageBreakCharacter, attributes: pageBreakAttributes(attrs))
    }

    /// A small rounded "chip" standing in for content the editor can't show yet.
    static func placeholderAttachment(_ label: String, font: NSFont?) -> NSTextAttachment {
        let font = NSFont.systemFont(ofSize: max(9, (font?.pointSize ?? 11) * 0.85))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let size = NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            (label as NSString).draw(at: NSPoint(x: 6, y: 2), withAttributes: attrs)
            return true
        }
        image.accessibilityDescription = label
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: font.descender - 2, width: size.width, height: size.height)
        return attachment
    }
}

// MARK: - Generating w:rPr

extension RunProperties {
    /// A `<w:rPr>` for these properties in schema order, or nil when there's nothing to say.
    public func xml() -> Data? {
        var parts: [String] = []
        if let styleId { parts.append("<w:rStyle w:val=\"\(RawXML.escapeAttribute(styleId))\"/>") }
        if let font {
            let f = RawXML.escapeAttribute(font)
            parts.append("<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:cs=\"\(f)\"/>")
        }
        if let bold { parts.append(bold ? "<w:b/>" : "<w:b w:val=\"0\"/>") }
        if let italic { parts.append(italic ? "<w:i/>" : "<w:i w:val=\"0\"/>") }
        if let strike { parts.append(strike ? "<w:strike/>" : "<w:strike w:val=\"0\"/>") }
        if let color { parts.append("<w:color w:val=\"\(RawXML.escapeAttribute(color))\"/>") }
        if let size {
            let half = Int((size * 2).rounded())
            parts.append("<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>")
        }
        if let highlight { parts.append("<w:highlight w:val=\"\(RawXML.escapeAttribute(highlight))\"/>") }
        if let underline { parts.append(underline ? "<w:u w:val=\"single\"/>" : "<w:u w:val=\"none\"/>") }
        if let verticalAlignment {
            parts.append("<w:vertAlign w:val=\"\(RawXML.escapeAttribute(verticalAlignment))\"/>")
        }
        guard !parts.isEmpty else { return nil }
        return Data(("<w:rPr>" + parts.joined() + "</w:rPr>").utf8)
    }
}
