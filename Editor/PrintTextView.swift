import AppKit
import LibretillaDocx

/// The view printing and PDF export lay the document out in (TextKit 2, like the editor). It starts a
/// new page after every page break and before every paragraph marked `w:pageBreakBefore`, doesn't draw
/// the editor's page break chips, and draws each page's header and footer. Each page draws only its own lines.
extension NSAttributedString.Key {
    /// On a footnote's number in printed text: the note's text, printed at the foot of the number's page.
    static let libretillaPrintedNote = NSAttributedString.Key("libretilla.printedNote")
}

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
        /// The number shown on this view's first page (`w:pgNumType`'s start, or where the previous section left
        /// off); nil for its position in the document, `pageOffset + 1`.
        var firstPageNumber: Int?

        /// The number shown on the view's page `page` (from 1), and how to write it.
        func pageNumber(_ page: Int) -> Int { (firstPageNumber ?? pageOffset + 1) + page - 1 }
        var pageNumberFormat: String? { setup.pageNumberFormat }
    }

    var decorations: Decorations?

    /// Draws the text while printing, in place of TextKit's own views (`PageText`).
    private let pageText = PageText()

    /// Bottom edges (view coordinates) of the lines that end in a page break, top to bottom.
    private var breakLineBottoms: [CGFloat] = []
    /// For each paragraph that starts a new page, top to bottom: the top edge of its layout fragment (above its
    /// first line and its space before) and the bottom edge of the line before it (view coordinates).
    private var breakBeforeLines: [(top: CGFloat, previousBottom: CGFloat)] = []
    /// Footnotes (backlog 24): the bottom of each reference's line with its note, every line's bottom (where a page
    /// may end), and the notes printed at the foot of each page (by its top).
    private var footnoteLines: [(bottom: CGFloat, note: NSAttributedString)] = []
    private var lineBottoms: [CGFloat] = []
    private var pageNotes: [Int: [NSAttributedString]] = [:]
    private var textWidth: CGFloat = 0

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
        textWidth = width
        if let storage = textStorage {
            storage.enumerateAttribute(
                .libretillaPrintedNote, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard let note = value as? NSAttributedString, let bottom = lineBottom(containing: range.location)
                else { return }
                footnoteLines.append((bottom, note))
            }
        }
        if !footnoteLines.isEmpty { lineBottoms = allLineBottoms() }
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

    /// AppKit (macOS 26) places each page's rectangle `bottomMargin` below the paper's top edge, for any text view, so
    /// a document's top and bottom margins came out swapped in print and PDF (backlog 39). Each page starts
    /// `topMargin` below the top, as Word's does.
    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint {
        let location = super.locationOfPrintRect(rect)
        guard let info = NSPrintOperation.current?.printInfo else { return location }
        return NSPoint(x: location.x, y: info.paperSize.height - info.topMargin - rect.height)
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

    /// `text` with placeholder chips replaced by what Word prints (backlog 27): a footnote or endnote reference by its
    /// number, a text box by its text, a comment by nothing, a block content control by its paragraphs. Other chips
    /// (equations, objects, symbols) print as they look in the editor.
    ///
    /// With `noteText` (a note's printed text, given its kind, `w:id` and number), each footnote's number carries its
    /// text (`.libretillaPrintedNote`), which the page it prints on shows at its foot, and endnotes are printed after
    /// the last paragraph, as in Word (backlog 24).
    static func printingObjects(
        _ text: NSAttributedString,
        noteText: ((OpaqueInline.NoteKind, String, String) -> NSAttributedString?)? = nil
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, NSAttributedString)] = []
        var notes: [OpaqueInline.NoteKind: Int] = [:]
        var endnotes: [NSAttributedString] = []
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, range, _ in
            guard attrs[.attachment] != nil else { return }
            var plain = attrs
            plain[.attachment] = nil
            if let inline = (attrs[.libretillaOpaque] as? OpaqueInlineBox)?.inline {
                if let kind = inline.noteReference {
                    notes[kind, default: 0] += 1
                    let n = notes[kind]!
                    let number = kind == .footnote ? String(n) : Self.lowerRoman(n)
                    let note = inline.noteId.flatMap { noteText?(kind, $0, number) }
                    if kind == .footnote, let note { plain[.libretillaPrintedNote] = note }
                    if kind == .endnote, let note { endnotes.append(note) }
                    replacements.append((range, NSAttributedString(string: number, attributes: plain)))
                } else if let printed = inline.printedText {
                    replacements.append((range, NSAttributedString(string: printed, attributes: plain)))
                }
            } else if let box = attrs[.libretillaBlock] as? OpaqueBlockBox, attrs[.libretillaTableRow] == nil,
                !box.block.visibleText.isEmpty
            {
                replacements.append((range, NSAttributedString(string: box.block.visibleText, attributes: plain)))
            }
        }
        for (range, replacement) in replacements.reversed() { out.replaceCharacters(in: range, with: replacement) }
        if !endnotes.isEmpty {
            // A short rule, then the notes, after the last paragraph.
            let attrs = out.length > 0 ? out.attributes(at: out.length - 1, effectiveRange: nil) : [:]
            var rule = attrs
            rule[.attachment] = Self.noteSeparator()
            rule[.libretillaPrintedNote] = nil
            if !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
            out.append(NSAttributedString(string: "\u{FFFC}\n", attributes: rule))
            for (i, note) in endnotes.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
                out.append(note)
            }
        }
        return out
    }

    /// Word's note separator: a line 2 inches long.
    static func noteSeparator() -> NSTextAttachment {
        let image = NSImage(size: NSSize(width: 144, height: 7), flipped: true) { rect in
            NSColor.black.setFill()
            NSRect(x: 0, y: 3, width: rect.width, height: 0.5).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 144, height: 7)
        return attachment
    }

    /// A note as printed: its number (superscript), then its paragraphs as the bridge shows them.
    static func noteText(_ story: HeadersFooters.Story, number: String, bridge: AttributedStringBridge)
        -> NSAttributedString
    {
        let text = NSMutableAttributedString(
            attributedString: printable(bridge.forStory(story).attributedString(for: story.body)))
        if text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        var attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        attrs[.attachment] = nil
        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 10)
        attrs[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 2 / 3) ?? font
        attrs[.baselineOffset] = font.pointSize / 3
        text.insert(NSAttributedString(string: number, attributes: attrs), at: 0)
        return text
    }

    /// i, ii, iii, … : Word's default endnote numbers.
    static func lowerRoman(_ n: Int) -> String {
        let values = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
            (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var n = n
        var out = ""
        for (value, letters) in values {
            while n >= value {
                out += letters
                n -= value
            }
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
        guard !footnoteLines.isEmpty else { return }
        // Room for the footnotes of the lines on the page: end the page a line earlier until they fit.
        func notes(_ bottom: CGFloat) -> [NSAttributedString] {
            footnoteLines.filter { $0.bottom > oldTop + 0.5 && $0.bottom <= bottom + 0.5 }.map(\.note)
        }
        // The bottom of the page's last line (the page may run past it, to the end of the text).
        func lastLine(_ bottom: CGFloat) -> CGFloat { lineBottoms.last { $0 <= bottom + 0.5 } ?? bottom }
        var bottom = newBottom.pointee
        while lastLine(bottom) + notesHeight(notes(bottom)) > oldBottom + 0.5,
            let earlier = lineBottoms.last(where: { $0 < lastLine(bottom) - 0.5 && $0 > oldTop + 0.5 })
        {
            bottom = earlier
        }
        newBottom.pointee = bottom
        pageNotes[Int(oldTop.rounded())] = notes(bottom)
    }

    /// The height of a page's footnotes: the separator, then each note.
    private func notesHeight(_ notes: [NSAttributedString]) -> CGFloat {
        notes.isEmpty ? 0 : Self.separatorRoom + notes.reduce(0) { $0 + Self.height(of: $1, width: textWidth) }
    }

    static let separatorRoom: CGFloat = 12

    /// The bottom of every laid-out line, top to bottom (view coordinates).
    private func allLineBottoms() -> [CGFloat] {
        guard let layout = textLayoutManager else { return [] }
        var out: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            fragment in
            let top = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
            for line in fragment.textLineFragments { out.append(top + line.typographicBounds.maxY) }
            return true
        }
        return out
    }

    /// Draws the footnotes of the page being printed above its bottom margin, under a short rule.
    private func drawNotes(paper: NSSize, flipped: Bool) {
        // Pages are laid out in order: the page being printed is the one with the nth top.
        guard let op = NSPrintOperation.current, case let tops = pageNotes.keys.sorted(),
            op.currentPage >= 1, op.currentPage <= tops.count,
            let notes = pageNotes[tops[op.currentPage - 1]], !notes.isEmpty
        else { return }
        let info = op.printInfo
        let left = info.leftMargin
        // From the top of the page.
        var y = paper.height - info.bottomMargin - notesHeight(notes)
        let rule = NSRect(x: left, y: y + 4, width: 144, height: 0.5)
        NSColor.black.setFill()
        NSRect(x: rule.minX, y: flipped ? rule.minY : paper.height - rule.maxY, width: rule.width, height: rule.height)
            .fill()
        y += Self.separatorRoom
        for note in notes {
            let height = Self.height(of: note, width: textWidth)
            // Drawn in a taller box: drawing clips a line that doesn't fit its box whole.
            let box = height + 20
            note.draw(
                with: NSRect(x: left, y: flipped ? y : paper.height - y - box, width: textWidth, height: box),
                options: Self.decorationOptions)
            y += height
        }
    }

    // MARK: Headers and footers

    /// Draws the page's header and footer: the header's top `w:header` below the page's top edge, the footer's
    /// bottom `w:footer` above its bottom edge, both across the text column. Page fields show this page's
    /// number and the page count.
    override func drawPageBorder(with borderSize: NSSize) {
        guard let op = NSPrintOperation.current, decorations != nil || !footnoteLines.isEmpty else { return }
        let saved = frame
        // As AppKit's documentation says: the page border is drawn in a frame the size of the paper.
        frame = NSRect(origin: .zero, size: borderSize)
        defer { frame = saved }
        let flipped = NSGraphicsContext.current?.isFlipped ?? isFlipped
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            drawNotes(paper: borderSize, flipped: flipped)
            guard let decorations else { return }
            // As in Word, the page's number (which can restart in a section) picks odd or even headers and footers.
            let page = decorations.pageNumber(op.currentPage)
            let pages = decorations.totalPages ?? NSMaxRange(op.pageRange) - 1
            for kind in HeadersFooters.Kind.allCases {
                guard
                    let text = Self.decorationText(
                        kind, page: page, of: pages, isFirstPage: op.currentPage == 1, decorations: decorations)
                else { continue }
                let setup = decorations.setup
                let options = Self.decorationOptions
                let height = Self.height(of: text, width: setup.textWidth)
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

    static let decorationOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(
            text.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude), options: decorationOptions
            ).height)
    }

    /// The page margins that keep the body clear of the headers and footers (backlog 8): as in Word, a header
    /// that reaches below the top margin pushes the body down, and a footer above the bottom margin pushes it up,
    /// unless the margin is negative ("exactly"). The tallest header and footer of the part count.
    static func margins(clearing decorations: Decorations) -> (top: CGFloat, bottom: CGFloat) {
        let setup = decorations.setup
        let distances = setup.headerFooterDistances
        func tallest(_ kind: HeadersFooters.Kind) -> CGFloat {
            HeadersFooters.Slot.allCases.compactMap { slot in
                decorations.headersFooters.stories[.init(kind, slot)].map {
                    height(of: text(of: $0, page: 1, of: 1, bridge: decorations.bridge), width: setup.textWidth)
                }
            }.max() ?? 0
        }
        var (top, bottom) = (setup.margins.top, setup.margins.bottom)
        if setup.top >= 0 { top = max(top, distances.header + tallest(.header)) }
        if setup.bottom >= 0 { bottom = max(bottom, distances.footer + tallest(.footer)) }
        return (top, bottom)
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
        return text(
            of: story, page: page, of: pages, format: decorations.pageNumberFormat, bridge: decorations.bridge)
    }

    /// A header or footer as printed on page `page` of `pages`.
    static func text(
        of story: HeadersFooters.Story, page: Int, of pages: Int, format: String? = nil, bridge: AttributedStringBridge
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: printable(
                bridge.forStory(story).attributedString(
                    for: story.printableBody(page: page, pages: pages, format: format))))
        // The last paragraph's terminator would add an empty line.
        if text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }
}
