import AppKit
import LibretillaDocx

/// The view printing and PDF export lay the document out in (TextKit 2, like the editor). It starts a
/// new page after every page break and before every paragraph marked `w:pageBreakBefore`, and doesn't draw
/// the editor's page break chips.
final class PrintTextView: NSTextView {
    /// Bottom edges (view coordinates) of the lines that end in a page break, top to bottom.
    private var breakLineBottoms: [CGFloat] = []
    /// For each paragraph that starts a new page, top to bottom: the top edge of its layout fragment (above its
    /// first line and its space before) and the bottom edge of the line before it (view coordinates).
    private var breakBeforeLines: [(top: CGFloat, previousBottom: CGFloat)] = []

    convenience init(text: NSAttributedString, width: CGFloat) {
        self.init(usingTextLayoutManager: true)
        // Paper is white: automatic text colour prints black even when the app is in Dark Mode.
        appearance = NSAppearance(named: .aqua)
        frame = NSRect(x: 0, y: 0, width: width, height: 100)
        isVerticallyResizable = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textStorage?.setAttributedString(Self.printable(text))
        sizeToFit()
        breakLineBottoms = pageBreakOffsets().compactMap(lineBottom(containing:)).sorted()
        breakBeforeLines = pageBreakBeforeOffsets().compactMap { start in
            guard let top = line(containing: start).map({ $0.frame.minY + textContainerOrigin.y }),
                let previous = lineBottom(containing: start - 1)
            else {
                return nil
            }
            return (top, previous)
        }
    }

    /// `text` with each page break chip replaced by a zero-width space: nothing is drawn, nothing odd ends up
    /// in the PDF's text, and the character (still marked as a page break) keeps its offset.
    static func printable(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var ranges: [NSRange] = []
        out.enumerateAttribute(.libretillaPageBreak, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        for range in ranges {
            out.removeAttribute(.attachment, range: range)
            out.replaceCharacters(in: range, with: String(repeating: "\u{200B}", count: range.length))
        }
        return out
    }

    private func pageBreakOffsets() -> [Int] {
        guard let storage = textStorage else { return [] }
        var offsets: [Int] = []
        storage.enumerateAttribute(.libretillaPageBreak, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if v != nil { offsets += Array(r.location..<NSMaxRange(r)) }
        }
        return offsets
    }

    /// The start of each paragraph marked `.libretillaPageBreakBefore` (on any of its characters, so text
    /// typed at its start still counts), except the document's first paragraph, which starts page 1 anyway.
    private func pageBreakBeforeOffsets() -> [Int] {
        guard let storage = textStorage else { return [] }
        let ns = storage.string as NSString
        var starts: Set<Int> = []
        storage.enumerateAttribute(.libretillaPageBreakBefore, in: NSRange(location: 0, length: storage.length)) {
            v, r, _ in
            if v != nil { starts.insert(ns.paragraphRange(for: NSRange(location: r.location, length: 0)).location) }
        }
        starts.remove(0)
        return starts.sorted()
    }

    /// The bottom of the laid-out line holding the character at `offset`.
    private func lineBottom(containing offset: Int) -> CGFloat? {
        line(containing: offset).map { $0.frame.minY + $0.line.typographicBounds.maxY + textContainerOrigin.y }
    }

    /// The laid-out line holding the character at `offset`, and the frame of its layout fragment.
    private func line(containing offset: Int) -> (line: NSTextLineFragment, frame: CGRect)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return nil }
        layout.ensureLayout(for: layout.documentRange)
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let inFragment = offset - start
        let lines = fragment.textLineFragments
        let line =
            lines.first { NSLocationInRange(inFragment, $0.characterRange) || inFragment < $0.characterRange.location }
            ?? lines.last
        guard let line else { return nil }
        return (line, fragment.layoutFragmentFrame)
    }

    /// Ends a page early at the first page break on it, or above the first paragraph on it that starts a new
    /// page. A paragraph with nothing above it on the page (it follows a page break, or the page just broke
    /// before it) already starts one. The page ends at the top of the paragraph's layout fragment, so the
    /// paragraph keeps its space before at the top of the new page, as in Word.
    override func adjustPageHeightNew(
        _ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat, bottom oldBottom: CGFloat,
        limit bottomLimit: CGFloat
    ) {
        super.adjustPageHeightNew(newBottom, top: oldTop, bottom: oldBottom, limit: bottomLimit)
        let limit = newBottom.pointee - 0.5
        let afterBreak = breakLineBottoms.first { $0 > oldTop + 0.5 && $0 < limit }
        let beforeParagraph = breakBeforeLines.first { $0.previousBottom > oldTop + 0.5 && $0.top < limit }?.top
        if let bottom = [afterBreak, beforeParagraph].compactMap({ $0 }).min() { newBottom.pointee = bottom }
    }
}
