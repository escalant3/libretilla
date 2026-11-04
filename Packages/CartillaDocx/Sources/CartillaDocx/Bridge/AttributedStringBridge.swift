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

    public init(styles: StyleSheet) {
        self.styles = styles
    }

    // MARK: - Model → text

    public func attributedString(for body: DocumentBody) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var pendingHidden: [OpaqueBlock] = []
        for block in body.blocks {
            switch block {
            case .paragraph(let p):
                out.append(paragraphText(p, leadingBlocks: pendingHidden))
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

    func paragraphText(_ p: Paragraph, leadingBlocks: [OpaqueBlock]) -> NSAttributedString {
        let (paragraphProps, _) = styles.resolveParagraphStyle(p.properties.styleId)
        let effective = p.properties.over(paragraphProps)
        let paragraphStyle = Self.paragraphStyle(effective)
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

        for inline in p.inlines {
            switch inline {
            case .run(let r):
                var attrs = characterAttributes(
                    styles.resolveRun(paragraphStyle: p.properties.styleId, direct: r.properties))
                attrs[.cartillaRun] = RunFormat(properties: r.properties, xml: r.propertiesXML)
                append(r.text, attrs)
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
                    attrs[.attachment] = Self.placeholderAttachment(label, font: attrs[.font] as? NSFont)
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
            paragraph: p, leadingBlocks: leadingBlocks, trailingMarkers: pendingMarkers, text: text.string,
            signature: Span.signature(of: text, in: NSRange(location: 0, length: contentLength)))
        text.append(NSAttributedString(string: "\n", attributes: terminator))
        text.addAttribute(.cartillaParagraph, value: origin, range: NSRange(location: 0, length: text.length))
        return text
    }

    func blockText(_ o: OpaqueBlock, leadingBlocks: [OpaqueBlock]) -> NSAttributedString {
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

            // Opaque block paragraphs (tables, content controls).
            if content.length > 0,
                let box = text.attribute(.cartillaBlock, at: content.location, effectiveRange: nil) as? OpaqueBlockBox
            {
                if emittedBlocks.insert(ObjectIdentifier(box)).inserted {
                    blocks += box.leadingBlocks.map(Block.opaque)
                    blocks.append(.opaque(box.block))
                }
                let rest = NSRange(location: content.location + 1, length: content.length - 1)
                if rest.length > 0 {
                    blocks.append(
                        .paragraph(
                            editedParagraph(
                                text, rest, origin: nil, keepSectionBreak: true,
                                emitted: &emittedOpaque, notices: &notices)))
                }
                continue
            }

            if let origin, isFirst { blocks += origin.leadingBlocks.map(Block.opaque) }

            if let origin, isFirst, isLast, text.attributedSubstring(from: content).string == origin.text,
                Span.signature(of: text, in: content) == origin.signature
            {
                blocks.append(.paragraph(origin.paragraph))
                Self.markEmitted(origin.paragraph, text, content, into: &emittedOpaque)
                continue
            }

            var p = editedParagraph(
                text, content, origin: origin, keepSectionBreak: isLast,
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
        // Body ends with sectPr: keep anything a paragraph needs before it.
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

    func editedParagraph(
        _ text: NSAttributedString, _ range: NSRange, origin: ParagraphOrigin?, keepSectionBreak: Bool,
        emitted: inout Set<ObjectIdentifier>, notices: inout [String]
    ) -> Paragraph {
        var p: Paragraph
        if let origin {
            p = origin.paragraph.edited()
            if !keepSectionBreak, let without = p.propertiesXMLWithoutSectionBreak {
                p.propertiesXML = without
                p.propertiesXMLWithoutSectionBreak = nil
                p.properties.hasSectionBreak = false
            }
        } else {
            p = Paragraph()
        }
        var inlines: [Inline] = []
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
            let plain = string.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !plain.isEmpty else { return }
            if let format = attrs[.cartillaRun] as? RunFormat {
                Self.appendRun(&inlines, Run(text: plain, properties: format.properties, propertiesXML: format.xml))
            } else {
                let props = Self.runProperties(fromDisplay: attrs)
                Self.appendRun(&inlines, Run(text: plain, properties: props, propertiesXML: props.xml()))
            }
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

    static func paragraphStyle(_ p: ParagraphProperties) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
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
