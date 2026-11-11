import AppKit
import LibretillaDocx

/// The view printing and PDF export lay the document out in (TextKit 2, like the editor). It starts a
/// new page after every page break and before every paragraph marked `w:pageBreakBefore`, doesn't draw
/// the editor's page break chips, and draws each page's header and footer. Each page draws only its own lines.
final class PrintTextView: NSTextView {
    /// The headers and footers to draw in the page margins, and how.
    struct Decorations {
        var headersFooters: HeadersFooters
        var differentFirstPage: Bool
        var bridge: AttributedStringBridge
        var setup: PageSetup
        /// Pages printed before this view's (earlier sections), and the whole document's page count if it isn't
        /// this view's own.
        var pageOffset = 0
        var totalPages: Int?
    }

    var decorations: Decorations?

    /// Draws the text while printing, in place of TextKit's own views (`PageText`).
    private let pageText = PageText()

    /// Bottom edges (view coordinates) of the lines that end in a page break, top to bottom.
    private var breakLineBottoms: [CGFloat] = []
    /// For each paragraph that starts a new page, top to bottom: the top edge of its layout fragment (above its
    /// first line and its space before) and the bottom edge of the line before it (view coordinates).
    private var breakBeforeLines: [(top: CGFloat, previousBottom: CGFloat)] = []

    convenience init(text: NSAttributedString, width: CGFloat) {
        self.init(usingTextLayoutManager: true)
        // List markers (gap G4).
        textLayoutManager?.delegate = ListMarkerLayout.shared
        // Paper is white: automatic text colour prints black even when the app is in Dark Mode.
        appearance = NSAppearance(named: .aqua)
        frame = NSRect(x: 0, y: 0, width: width, height: 100)
        isVerticallyResizable = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textStorage?.setAttributedString(Self.printable(text))
        sizeToFit()
        // Drawing headers and footers changes the frame for a moment; the text must not reflow.
        textContainer?.widthTracksTextView = false
        breakLineBottoms = pageBreakOffsets().compactMap(lineBottom(containing:)).sorted()
        breakBeforeLines = pageBreakBeforeOffsets().compactMap { start in
            guard let top = line(containing: start).map({ $0.frame.minY + textContainerOrigin.y }),
                let previous = lineBottom(containing: start - 1)
            else {
                return nil
            }
            return (top, previous)
        }
        pageText.textView = self
        pageText.frame = bounds
        pageText.autoresizingMask = [.width, .height]
        addSubview(pageText)
    }

    // MARK: Drawing the text

    /// TextKit 2 draws each paragraph whole, in its own views, so a paragraph split across pages would be drawn
    /// on both, clipped. Clipping hides the other page's lines but keeps their text in the PDF, where search, copy
    /// and VoiceOver find it (backlog 25). This view draws, for each page, only the lines on it.
    private final class PageText: NSView {
        weak var textView: PrintTextView?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { textView?.drawLines(in: dirtyRect) }
    }

    override func beginDocument() {
        super.beginDocument()
        pageText.frame = bounds
        for view in subviews where view !== pageText { view.isHidden = true }
    }

    override func endDocument() {
        for view in subviews where view !== pageText { view.isHidden = false }
        super.endDocument()
    }

    /// Draws the lines whose middle is in `rect` (a page, in view coordinates).
    private func drawLines(in rect: NSRect) {
        guard let layout = textLayoutManager, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = textContainerOrigin
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY < rect.maxY else { return false }
            guard frame.maxY > rect.minY || fragment.renderingSurfaceBounds.maxY + frame.minY > rect.minY else {
                return true
            }
            fragment.drawLines(at: frame.origin, in: context) { line in
                let middle = frame.minY + line.typographicBounds.midY
                return middle >= rect.minY && middle < rect.maxY
            }
            return true
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

    // MARK: Headers and footers

    /// Draws the page's header and footer: the header's top `w:header` below the page's top edge, the footer's
    /// bottom `w:footer` above its bottom edge, both across the text column. Page fields show this page's
    /// number and the page count.
    override func drawPageBorder(with borderSize: NSSize) {
        guard let decorations, let op = NSPrintOperation.current else { return }
        let page = op.currentPage + decorations.pageOffset
        let pages = decorations.totalPages ?? NSMaxRange(op.pageRange) - 1
        let saved = frame
        // As AppKit's documentation says: the page border is drawn in a frame the size of the paper.
        frame = NSRect(origin: .zero, size: borderSize)
        defer { frame = saved }
        let flipped = NSGraphicsContext.current?.isFlipped ?? isFlipped
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for kind in HeadersFooters.Kind.allCases {
                guard
                    let text = Self.decorationText(
                        kind, page: page, of: pages, isFirstPage: op.currentPage == 1, decorations: decorations)
                else { continue }
                let setup = decorations.setup
                let size = NSSize(width: setup.textWidth, height: .greatestFiniteMagnitude)
                let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
                let height = ceil(text.boundingRect(with: size, options: options).height)
                let distances = setup.headerFooterDistances
                // From the top of the page.
                let top = kind == .header ? distances.header : borderSize.height - distances.footer - height
                let rect = NSRect(
                    x: setup.margins.left, y: flipped ? top : borderSize.height - top - height,
                    width: setup.textWidth, height: height)
                text.draw(with: rect, options: options)
            }
        }
    }

    /// The header or footer text for page `page` of `pages`, or nil if the page has none. `isFirstPage`: whether
    /// it's the first page of its section (by default, of the document).
    static func decorationText(
        _ kind: HeadersFooters.Kind, page: Int, of pages: Int, isFirstPage: Bool? = nil, decorations: Decorations
    ) -> NSAttributedString? {
        guard
            let story = decorations.headersFooters.story(
                kind, page: page, differentFirstPage: decorations.differentFirstPage, isFirstPage: isFirstPage),
            !story.isEmpty
        else { return nil }
        let text = NSMutableAttributedString(
            attributedString: printable(
                decorations.bridge.forStory(story).attributedString(
                    for: story.printableBody(page: page, pages: pages))))
        // The last paragraph's terminator would add an empty line.
        if text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }
}
