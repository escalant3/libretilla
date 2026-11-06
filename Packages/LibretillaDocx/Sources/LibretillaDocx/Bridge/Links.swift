import AppKit

// Editing links (Insert ▸ Link…). Links Libretilla models are `w:hyperlink`s of plain runs; their text
// carries a `HyperlinkBox` (`.libretillaHyperlink`) and the URL (`.link`).

extension AttributedStringBridge {
    /// The whole link at `location` (a caret just inside or a selection within it), with its box.
    public static func link(at location: Int, in text: NSAttributedString) -> (range: NSRange, box: HyperlinkBox)? {
        for at in [location, location - 1] where at >= 0 && at < text.length {
            var range = NSRange()
            if let box = text.attribute(
                .libretillaHyperlink, at: at, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: text.length)) as? HyperlinkBox
            {
                return (range, box)
            }
        }
        return nil
    }

    /// Makes `range` a link to `url` (one link per paragraph it touches). Text that's already a link is
    /// retargeted instead. `hyperlinkStyleId` is the document's "Hyperlink" character style, if any; new
    /// link text takes it, as in Word.
    public func setLink(
        _ url: String, in text: NSMutableAttributedString, range: NSRange, hyperlinkStyleId: String?
    ) {
        guard range.length > 0, let parsed = URL(string: url) else { return }
        for paragraph in Self.paragraphRanges(in: text, touching: range) {
            var r = NSIntersectionRange(paragraph, range)
            // Never include the paragraph terminator.
            if r.length > 0, NSMaxRange(r) == NSMaxRange(paragraph),
                (text.string as NSString).character(at: NSMaxRange(r) - 1) == 0x0A
            {
                r.length -= 1
            }
            guard r.length > 0 else { continue }
            let existing = text.attribute(.libretillaHyperlink, at: r.location, effectiveRange: nil) as? HyperlinkBox
            let link = existing.map { $0.link.retargeted(to: url) } ?? Hyperlink(target: url, runs: [])
            let box = HyperlinkBox(link, url: parsed)
            text.addAttribute(.libretillaHyperlink, value: box, range: r)
            text.addAttribute(.link, value: parsed, range: r)
            if existing == nil, let hyperlinkStyleId {
                apply(.characterStyle(hyperlinkStyleId), to: text, range: r)
            }
        }
    }

    /// Removes the links in `range` (their text stays), and the "Hyperlink" character style with them.
    public func removeLinks(in text: NSMutableAttributedString, range: NSRange, hyperlinkStyleId: String?) {
        guard range.length > 0 else { return }
        var linked: [NSRange] = []
        text.enumerateAttribute(.libretillaHyperlink, in: range) { v, r, _ in if v != nil { linked.append(r) } }
        for r in linked {
            text.removeAttribute(.libretillaHyperlink, range: r)
            text.removeAttribute(.link, range: r)
            guard let hyperlinkStyleId else { continue }
            var styled: [NSRange] = []
            text.enumerateAttribute(.libretillaRun, in: r) { v, span, _ in
                if (v as? RunFormat)?.properties.styleId == hyperlinkStyleId { styled.append(span) }
            }
            for span in styled { apply(.characterStyle(nil), to: text, range: span) }
        }
    }

    /// New link text to insert at the caret: `title` linking to `url`, in the caret's formatting plus the
    /// "Hyperlink" character style.
    public func linkText(
        _ title: String, url: String, typingAttributes: [NSAttributedString.Key: Any], paragraphStyle styleId: String?,
        hyperlinkStyleId: String?
    ) -> NSAttributedString? {
        guard !title.isEmpty, let parsed = URL(string: url) else { return nil }
        var attrs = typingAttributes
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        let out = NSMutableAttributedString(string: title, attributes: attrs)
        let whole = NSRange(location: 0, length: out.length)
        if let hyperlinkStyleId {
            let format = runFormat(attrs, paragraphStyle: styleId)
            let styled = applying(.characterStyle(hyperlinkStyleId), to: format, paragraphStyle: styleId)
            Self.setDisplay(displayAttributes(for: styled, paragraphStyle: styleId), on: out, range: whole)
            out.addAttribute(.libretillaRun, value: styled, range: whole)
        }
        out.addAttribute(
            .libretillaHyperlink, value: HyperlinkBox(Hyperlink(target: url, runs: []), url: parsed), range: whole)
        out.addAttribute(.link, value: parsed, range: whole)
        return out
    }
}
