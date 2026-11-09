import AppKit

// List markers (gap G4 in docs/TEXTKIT2_GAPS.md). TextKit 2 lays out paragraphs with `NSTextList`s itself: it
// ignores their indents and indents by nesting depth. So list paragraphs carry no `NSTextList`: they're laid out
// with their real Word indents, and `ListMarkerLayout` draws the marker in front of the first line, where Word
// puts it.

/// The marker drawn in front of a list paragraph's first line (`.libretillaListMarker`). Display only: the
/// paragraph's numbering is in its `ParagraphFormat`.
public final class ListMarker: NSObject, @unchecked Sendable {
    /// The literal marker Word shows ("•", "2.3.", "iv)").
    public let text: String
    /// Where the marker starts and where the first line's text starts, from the text column's left edge (points).
    public let x: CGFloat
    public let textStart: CGFloat

    public init(text: String, x: CGFloat, textStart: CGFloat) {
        self.text = text
        self.x = x
        self.textStart = textStart
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ListMarker else { return false }
        return text == other.text && x == other.x && textStart == other.textStart
    }

    public override var hash: Int { text.hashValue ^ x.hashValue }
}

extension NSAttributedString.Key {
    /// A `ListMarker` on every character of a list paragraph.
    public static let libretillaListMarker = NSAttributedString.Key("libretilla.listMarker")
}

extension AttributedStringBridge {
    /// The marker shown on `paragraph`, if it's a list item.
    public static func listMarker(in text: NSAttributedString, paragraph: NSRange) -> ListMarker? {
        guard paragraph.length > 0 else { return nil }
        return text.attribute(.libretillaListMarker, at: paragraph.location, effectiveRange: nil) as? ListMarker
    }

    /// The font and colour a marker is drawn in: those of the paragraph's first character that is text (its
    /// paragraph mark if it has none), as Word draws a marker in the paragraph mark's formatting.
    static func markerAttributes(_ paragraph: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let ns = paragraph.string as NSString
        var index = 0
        while index < ns.length - 1, paragraph.attribute(.attachment, at: index, effectiveRange: nil) != nil {
            index += 1
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        if ns.length > 0 {
            let at = paragraph.attributes(at: index, effectiveRange: nil)
            attrs[.font] = (at[.font] as? NSFont).map {
                NSFont(descriptor: $0.fontDescriptor, size: $0.pointSize) ?? $0
            }
            // Superscript text doesn't make the marker small.
            if at[.superscript] != nil, let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize / scriptScale)
            }
            attrs[.foregroundColor] = at[.foregroundColor]
        }
        if attrs[.font] == nil { attrs[.font] = NSFont.systemFont(ofSize: defaultFontSize) }
        return attrs
    }

    /// Where Word puts a list paragraph's marker and its first line's text: the marker at the first-line (or
    /// hanging) indent, then a tab to the left indent when there's a hanging indent and the marker fits before
    /// it, or else to the next tab stop.
    static func listMarker(_ marker: String, paragraph p: ParagraphProperties, font: NSFont) -> ListMarker {
        let left = CGFloat(p.indentLeft ?? 0)
        let x = max(0, left + CGFloat(p.firstLine ?? 0))
        let width = (marker as NSString).size(withAttributes: [.font: font]).width
        let end = x + width
        let textStart: CGFloat
        if x < left, end <= left {
            textStart = left
        } else if let tab = (p.tabs ?? []).map({ CGFloat($0.position) }).sorted().first(where: { $0 > end }) {
            textStart = tab
        } else {
            textStart = ((end + 0.01) / defaultTabInterval).rounded(.up) * defaultTabInterval
        }
        return ListMarker(text: marker, x: x, textStart: textStart)
    }

    /// Shows `marker` (nil: none) on `paragraph`: the marker attribute, and the first line starting where Word
    /// starts its text.
    func setListMarker(_ marker: String?, on text: NSMutableAttributedString, paragraph: NSRange) {
        guard paragraph.length > 0 else { return }
        // Unchanged attributes are left alone: any edit, even one setting the same value, makes TextKit lay the
        // paragraph out again, and renumbering visits every paragraph.
        guard let marker else {
            var present = false
            text.enumerateAttribute(.libretillaListMarker, in: paragraph) { v, _, stop in
                if v != nil {
                    present = true
                    stop.pointee = true
                }
            }
            if present { text.removeAttribute(.libretillaListMarker, range: paragraph) }
            return
        }
        let effective = effectiveParagraph(format(of: text, paragraph: paragraph).properties)
        let font =
            Self.markerAttributes(text.attributedSubstring(from: paragraph))[.font] as? NSFont
            ?? NSFont.systemFont(ofSize: Self.defaultFontSize)
        let list = Self.listMarker(marker, paragraph: effective, font: font)
        var shown: NSRange = NSRange(location: NSNotFound, length: 0)
        let current = text.attribute(
            .libretillaListMarker, at: paragraph.location, longestEffectiveRange: &shown, in: paragraph)
        if (current as? ListMarker) != list || shown != paragraph {
            text.addAttribute(.libretillaListMarker, value: list, range: paragraph)
        }
        if let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle,
            abs(style.firstLineHeadIndent - list.textStart) > 0.01,
            let new = style.mutableCopy() as? NSMutableParagraphStyle
        {
            new.firstLineHeadIndent = list.textStart
            text.addAttribute(.paragraphStyle, value: new, range: paragraph)
        }
    }
}

/// Lays out list paragraphs with a fragment that draws their marker. Set it as the delegate of every text layout
/// manager that shows the bridge's text (the editor, printing, headers and footers).
public final class ListMarkerLayout: NSObject, NSTextLayoutManagerDelegate, Sendable {
    public static let shared = ListMarkerLayout()

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString, paragraph.length > 0,
            let marker = paragraph.attribute(.libretillaListMarker, at: 0, effectiveRange: nil) as? ListMarker
        else { return NSTextLayoutFragment(textElement: textElement, range: range) }
        let text = NSAttributedString(
            string: marker.text, attributes: AttributedStringBridge.markerAttributes(paragraph))
        return ListMarkerFragment(textElement: textElement, range: range, marker: text, x: marker.x)
    }
}

/// A list paragraph's layout: its text, and its marker drawn on the first line's baseline at `x`.
final class ListMarkerFragment: NSTextLayoutFragment, @unchecked Sendable {
    let marker: NSAttributedString
    let x: CGFloat

    init(textElement: NSTextElement, range: NSTextRange?, marker: NSAttributedString, x: CGFloat) {
        self.marker = marker
        self.x = x
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    /// The marker's rectangle in the fragment's coordinates, top-left origin.
    private var markerRect: CGRect? {
        guard let line = textLineFragments.first,
            let font = marker.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else { return nil }
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        let size = marker.size()
        return CGRect(
            x: x - layoutFragmentFrame.minX, y: baseline - font.ascender, width: size.width, height: size.height)
    }

    override var renderingSurfaceBounds: CGRect {
        guard let markerRect else { return super.renderingSurfaceBounds }
        return super.renderingSurfaceBounds.union(markerRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let markerRect else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        marker.draw(at: NSPoint(x: point.x + markerRect.minX, y: point.y + markerRect.minY))
        NSGraphicsContext.restoreGraphicsState()
    }
}
