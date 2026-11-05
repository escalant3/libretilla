import AppKit
import CartillaDocx
import os

/// A page-width text column on a quiet canvas (bootstrap §5.1 "page view", stage 1).
/// True pagination is a v1.1 milestone.
final class EditorViewController: NSViewController, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    /// The document's page size and margins (from its final `w:sectPr`); set with `apply(_:)`.
    private(set) var pageSetup = PageSetup.fallback

    private(set) var textView: CartillaTextView!
    private var canvas: PageCanvasView!
    private var scrollView: NSScrollView!
    /// The cell editor sheet while it's open.
    var tableEditor: TableEditorController?

    /// Off (the default): the paper fills the window, with the text column centred at the document's text
    /// width. On: a page with its edges on a gray canvas (View ▸ Show Page Edges).
    var showsPageEdges = false {
        didSet {
            loadViewIfNeeded()
            canvas.showsPageEdges = showsPageEdges
            applyPageAppearance()
        }
    }
    /// View zoom, as in Google Docs: the page is magnified (⌘+ / ⌘− / ⌘0, the format bar, or a pinch);
    /// the document's font sizes don't change. 1 is 100%.
    var zoom: CGFloat {
        get { scrollView?.magnification ?? 1 }
        set { setZoom(newValue) }
    }
    /// Called after the zoom changes (commands, the format bar, or a pinch ending).
    var onZoomChange: ((CGFloat) -> Void)?
    static let zoomLevels: [CGFloat] = [0.5, 0.75, 0.9, 1, 1.25, 1.5, 2]
    /// Supplies the styles and lists the text is mapped through (formatting commands, saving).
    weak var document: CartillaDocument?
    /// Called (coalesced) when the selection or its formatting changes, for the format bar.
    var onSelectionFormatChange: ((SelectionFormat, AttributedStringBridge) -> Void)?
    /// Called (debounced) with the document's headings after the text changes, for the outline sidebar.
    var onHeadingsChange: (([OutlineHeading]) -> Void)? {
        didSet { scheduleOutlineUpdate(delay: 0) }
    }
    /// The headings as of the last outline update (VoiceOver's rotor reads them too).
    private(set) var headings: [OutlineHeading] = []
    private var outlineUpdate: DispatchWorkItem?

    /// Settings ▸ "Page in Dark Mode": false (the default) shows a dark page in Dark Mode; true keeps the page
    /// white with dark text, as it prints.
    var keepsPageLight = false {
        didSet {
            loadViewIfNeeded()
            applyPageAppearance()
        }
    }

    /// While loading, storage edits are the bridge's own and need no reconciling.
    private var isLoading = false
    private var renumberScheduled = false
    private var selectionUpdateScheduled = false

    var bridge: AttributedStringBridge { document?.bridge ?? CartillaDocument.emptyBridge }
    nonisolated(unsafe) private var fallbackObserver: (any NSObjectProtocol)?
    nonisolated private static let log = Logger(subsystem: "app.cartilla.Cartilla", category: "Editor")

    deinit {
        if let fallbackObserver { NotificationCenter.default.removeObserver(fallbackObserver) }
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // Zoomed in, the page can be wider than the window.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.zoomLevels.first!
        scrollView.maxMagnification = Self.zoomLevels.last!
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = true

        let canvas = PageCanvasView()
        scrollView.documentView = canvas

        // TextKit 2, deliberately (ADR 0001). Never touch `textView.layoutManager`: it forces a
        // permanent fallback to TextKit 1. Known TK2 gaps: docs/TEXTKIT2_GAPS.md.
        let textView = CartillaTextView(usingTextLayoutManager: true)
        // The text view is the page's text column; the canvas draws the page around it. (A horizontal
        // textContainerInset would misplace the ruler's right-indent marker.)
        textView.frame = NSRect(x: 0, y: 0, width: pageSetup.textWidth, height: pageSetup.pageSize.height)
        textView.isRichText = true
        // Dropped and pasted images become pictures (saved as new media on the next save).
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesRuler = true
        textView.usesFontPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.textContainer?.widthTracksTextView = true
        // Text starts exactly at the margin, as in Word (so lines wrap at Word's text width too).
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = false
        textView.setAccessibilityLabel(String(localized: "Document body"))
        // Links look as their Word style says (usually "Hyperlink"), not AppKit's blue.
        textView.linkTextAttributes = [:]
        textView.delegate = self
        textView.structureDelegate = self
        textView.headingsProvider = { [weak self] in self?.currentHeadings() ?? [] }
        textView.onEffectiveAppearanceChange = { [weak self] in self?.invalidateReadableColors() }
        textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layout, fragment in
            MainActor.assumeIsolated { self?.validateReadableColors(layout, fragment) }
        }
        textView.textStorage?.delegate = self
        canvas.page = textView
        self.textView = textView
        self.canvas = canvas
        self.scrollView = scrollView
        fallbackObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main
        ) { _ in
            // Something forced TextKit 1. Record it as a new gap in docs/TEXTKIT2_GAPS.md.
            Self.log.fault("NSTextView fell back to TextKit 1")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEndLiveMagnify), name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView)
        view = scrollView
        apply(pageSetup)
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) {
        setZoom(Self.zoomLevels.first { $0 > zoom + 0.001 } ?? zoom)
    }

    @objc func zoomOut(_ sender: Any?) {
        setZoom(Self.zoomLevels.last { $0 < zoom - 0.001 } ?? zoom)
    }

    @objc func zoomToActualSize(_ sender: Any?) { setZoom(1) }

    /// The format bar's zoom menu (the item's represented object is the zoom).
    @objc func applyZoom(_ sender: Any?) {
        let item = (sender as? NSPopUpButton)?.selectedItem ?? sender as? NSMenuItem
        if let value = item?.representedObject as? CGFloat { setZoom(value) }
        view.window?.makeFirstResponder(textView)
    }

    private func setZoom(_ value: CGFloat) {
        loadViewIfNeeded()
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        // As in Google Docs: the line in the middle of the window stays there, and the page stays
        // centred across (when it's wider than the window, the view shows its middle).
        let anchor = scrollView.documentVisibleRect.midY
        scrollView.magnification = clamped
        fitCanvas()
        let clip = scrollView.contentView
        let visible = scrollView.documentVisibleRect.size
        let x = (canvas.frame.width - clip.bounds.width) / 2
        let wanted = NSRect(x: x, y: anchor - visible.height / 2, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
        onZoomChange?(scrollView.magnification)
    }

    /// Resizes the canvas for the zoom, then lets the scroll view show or hide its scrollers for the new
    /// size (which changes the clip's size, so the canvas is fitted again).
    private func fitCanvas() {
        canvas.layoutSubtreeIfNeeded()
        scrollView.tile()
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
    }

    @objc private func didEndLiveMagnify(_ note: Notification) {
        fitCanvas()
        onZoomChange?(scrollView.magnification)
    }

    // MARK: Page

    /// Lays the page out for `setup`: the text view is the text column, the canvas draws the page around
    /// it. The top margin is the inset above the text (TextKit's inset is symmetric, so the space below the
    /// last line is the top margin too; continuous scroll has no page bottoms anyway).
    func apply(_ setup: PageSetup) {
        loadViewIfNeeded()
        pageSetup = setup
        let column = setup.textWidth
        let margins = setup.margins
        canvas.pageWidth = setup.pageSize.width
        canvas.leftMargin = margins.left
        canvas.columnWidth = column
        textView.textContainerInset = NSSize(width: 0, height: margins.top)
        // The canvas sets the width: the document's text width, or narrower when the window is (it rewraps).
        textView.minSize = NSSize(width: PageCanvasView.minimumColumn, height: setup.pageSize.height)
        textView.maxSize = NSSize(width: column, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: column, height: max(textView.frame.height, setup.pageSize.height)))
        canvas.needsLayout = true
        canvas.needsDisplay = true
    }

    // MARK: Content

    /// Replaces the content without registering an undo action or marking the document edited
    /// (opening a file must never rewrite it).
    func show(_ text: NSAttributedString, editable: Bool) {
        loadViewIfNeeded()
        isLoading = true
        textView.textStorage?.setAttributedString(text)
        isLoading = false
        scheduleOutlineUpdate(delay: 0)
        textView.isEditable = editable
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        scheduleSelectionUpdate()
    }

    /// An immutable copy of the current content, for saving off the main thread.
    func textSnapshot() -> NSAttributedString {
        NSAttributedString(attributedString: textView.textStorage ?? NSTextStorage())
    }

    /// Replaces everything as one undoable edit (Restore Original…).
    func replaceAllUndoably(_ text: NSAttributedString) {
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: all, replacementString: text.string) else { return }
        textView.textStorage?.replaceCharacters(in: all, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Redraws every paragraph (after the style sheet changed).
    func restyleAll() {
        guard let storage = textView.textStorage else { return }
        let bridge = self.bridge
        isLoading = true
        storage.beginEditing()
        for p in AttributedStringBridge.paragraphRanges(
            in: storage, touching: NSRange(location: 0, length: storage.length))
        {
            bridge.restyle(storage, paragraph: p)
        }
        bridge.renumber(storage)
        storage.endEditing()
        isLoading = false
        scheduleSelectionUpdate()
    }

    // MARK: NSTextStorageDelegate

    /// AppKit's own tools (Font panel, ruler, paste) change display attributes directly; work out
    /// which Word properties that means. Cartilla's own commands are already consistent (no-op).
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedRange.location != NSNotFound else { return }
        // Restyling (Undo of a style change, Update Style) changes headings too.
        scheduleOutlineUpdate()
        if pageIsDark, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let from = content.location(content.documentRange.location, offsetBy: editedRange.location),
            let to = content.location(from, offsetBy: editedRange.length),
            let range = NSTextRange(location: from, end: to)
        {
            layout.invalidateRenderingAttributes(for: range)
        }
        guard !isLoading else { return }
        if editedMask.contains(.editedCharacters) { fitNewPictures(in: textStorage, range: editedRange) }
        bridge.reconcile(textStorage, range: editedRange)
        // Splitting, joining or reformatting paragraphs can change list numbers further down.
        if !bridge.numbering.nums.isEmpty { scheduleRenumber() }
    }

    private func scheduleRenumber() {
        guard !renumberScheduled else { return }
        renumberScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            self.renumberScheduled = false
            // Markers are display only: no undo action, no change to the document.
            self.withoutReconciling {
                storage.beginEditing()
                self.bridge.renumber(storage)
                storage.endEditing()
            }
        }
    }

    /// Storage edits that are the bridge's own (display only) and need no reconciling.
    func withoutReconciling(_ body: () -> Void) {
        let was = isLoading
        isLoading = true
        body()
        isLoading = was
    }

    func scheduleSelectionUpdate() {
        guard !selectionUpdateScheduled else { return }
        selectionUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            self.selectionUpdateScheduled = false
            let bridge = self.bridge
            let format = bridge.selectionFormat(
                storage, range: self.textView.selectedRange(), typingAttributes: self.textView.typingAttributes)
            self.onSelectionFormatChange?(format, bridge)
        }
    }

    // MARK: NSTextViewDelegate

    /// Content Cartilla only preserves (links, fields, objects, tables) is edited whole or not at all.
    /// Formatting changes (no replacement string) are always allowed; they skip such content.
    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        guard let storage = textView.textStorage, replacementString != nil else { return true }
        return Self.editIsAllowed(affectedCharRange, in: storage)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        scheduleSelectionUpdate()
        onCaretMove?(textView.selectedRange().location)
    }

    /// Called when the caret moves, so the outline can select the heading it's under.
    var onCaretMove: ((Int) -> Void)?

    func textDidChange(_ notification: Notification) { scheduleSelectionUpdate() }

    /// Typed text never joins a link, field or object, nor copies its markers.
    func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = newTypingAttributes
        for key in NSAttributedString.Key.cartillaNonInheritable { attrs[key] = nil }
        // Typing inside a link (not at either end) extends it, as in Word.
        if let storage = textView.textStorage, let link = linkAround(caret: textView.selectedRange(), in: storage) {
            attrs[.cartillaHyperlink] = link.box
            if let url = link.box.url { attrs[.link] = url }
        }
        return attrs
    }

    static func editIsAllowed(_ range: NSRange, in text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return true }
        let start = max(0, range.location - 1)
        let probe = NSRange(location: start, length: min(text.length - start, range.length + 2))
        let everything = NSRange(location: 0, length: text.length)
        var allowed = true
        for key in [NSAttributedString.Key.cartillaOpaque, .cartillaBlock] where allowed {
            text.enumerateAttribute(key, in: probe) { value, r, stop in
                guard value != nil else { return }
                var whole = NSRange()
                _ = text.attribute(key, at: r.location, longestEffectiveRange: &whole, in: everything)
                let overlap = NSIntersectionRange(whole, range).length
                let inside = range.location > whole.location && range.location < NSMaxRange(whole)
                if (range.length == 0 && inside) || (overlap > 0 && overlap < whole.length) {
                    allowed = false
                    stop.pointee = true
                }
            }
        }
        return allowed
    }
}

// MARK: - Outline

extension EditorViewController {
    /// Recomputes the headings after typing stops for a moment (immediately when `delay` is 0).
    func scheduleOutlineUpdate(delay: TimeInterval = 0.3) {
        outlineUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateOutline() }
        }
        outlineUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func updateOutline() {
        outlineUpdate?.cancel()
        outlineUpdate = nil
        guard let storage = textView?.textStorage else { return }
        headings = DocumentOutline.headings(in: storage, styles: bridge.styles)
        onHeadingsChange?(headings)
    }

    /// Up-to-date headings (VoiceOver may ask before a pending update has run).
    func currentHeadings() -> [OutlineHeading] {
        if outlineUpdate != nil { updateOutline() }
        return headings
    }

    /// Puts the caret at the start of `heading` and scrolls it to the top of the window.
    func go(to heading: OutlineHeading) {
        guard let storage = textView.textStorage, NSMaxRange(heading.range) <= storage.length else { return }
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: heading.range.location, length: 0))
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: heading.range.location)
        else {
            textView.scrollRangeToVisible(heading.range)
            return
        }
        // TextKit 2 estimates the height of text it hasn't laid out: lay out everything up to the heading so
        // its position is exact, and size the view for it, before scrolling.
        layout.ensureLayout(
            for: NSTextRange(location: content.documentRange.location, end: location) ?? NSTextRange(location: location)
        )
        textView.sizeToFit()
        canvas.layoutSubtreeIfNeeded()
        guard let fragment = layout.textLayoutFragment(for: location) else { return }
        // The heading's first line, not its space before.
        let lineTop = fragment.textLineFragments.first?.typographicBounds.minY ?? 0
        let top = fragment.layoutFragmentFrame.minY + lineTop + textView.textContainerOrigin.y
        let inCanvas = canvas.convert(NSPoint(x: 0, y: top), from: textView)
        // A little air above the heading. The clip's bounds may start under the title bar and format bar:
        // measure how far above the visible area they start.
        let clip = scrollView.contentView
        let hidden = scrollView.documentVisibleRect.minY - clip.bounds.minY
        let y = inCanvas.y - 12 - hidden
        let wanted = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Dark Mode

extension EditorViewController {
    /// A light page has the light appearance, so its paper, text colour, caret and selection are as printed.
    /// The canvas around it and the scrollers follow the window.
    func applyPageAppearance() {
        let light = keepsPageLight ? NSAppearance(named: .aqua) : nil
        textView.appearance = light
        canvas.pageAppearance = light
        scrollView.backgroundColor =
            showsPageEdges ? .underPageBackgroundColor : (keepsPageLight ? .white : .textBackgroundColor)
        invalidateReadableColors()
    }

    var pageIsDark: Bool {
        textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func invalidateReadableColors() {
        guard let layout = textView?.textLayoutManager else { return }
        layout.invalidateRenderingAttributes(for: layout.documentRange)
        textView.needsDisplay = true
    }

    /// On a dark page, text in a dark colour Word chose for a white page (black, navy headings, link blue) is
    /// drawn lighter, and text on a highlight is drawn dark. Display only: these are TextKit rendering
    /// attributes, so the document's colours are untouched.
    func validateReadableColors(_ layout: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
        guard pageIsDark, let storage = textView.textStorage, let content = layout.textContentManager else { return }
        let fragmentRange = fragment.rangeInElement
        let start = content.offset(from: content.documentRange.location, to: fragmentRange.location)
        let end = content.offset(from: content.documentRange.location, to: fragmentRange.endLocation)
        guard start >= 0, end <= storage.length, end > start else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: fragmentRange)
        storage.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attrs, range, _ in
            let color = attrs[.foregroundColor] as? NSColor
            let highlighted = attrs[.backgroundColor] != nil
            guard let shown = Self.readableColor(color, onHighlight: highlighted),
                let from = content.location(content.documentRange.location, offsetBy: range.location),
                let to = content.location(from, offsetBy: range.length),
                let textRange = NSTextRange(location: from, end: to)
            else { return }
            layout.setRenderingAttributes([.foregroundColor: shown], for: textRange)
        }
    }

    /// The colour to draw `color` in on a dark page, or nil to draw it as it is.
    nonisolated static func readableColor(_ color: NSColor?, onHighlight: Bool) -> NSColor? {
        // Highlights keep their light colours, so the text on them is drawn dark, as in Word's Dark Mode.
        if onHighlight {
            guard let rgb = color?.usingColorSpace(.sRGB), color?.type != .catalog else { return .black }
            return luminance(rgb) > 0.4 ? .black : nil
        }
        // Automatic colour (a system colour) already adapts.
        guard let color, color.type != .catalog, let rgb = color.usingColorSpace(.sRGB) else { return nil }
        // 4.5:1 against the dark page (luminance ≈ 0.015) needs a luminance of about 0.25.
        let wanted: CGFloat = 0.25
        guard luminance(rgb) < wanted else { return nil }
        if rgb.saturationComponent < 0.15 { return .textColor }
        var t: CGFloat = 0.1
        while t < 1 {
            if let mixed = rgb.blended(withFraction: t, of: .white), luminance(mixed) >= wanted { return mixed }
            t += 0.1
        }
        return .textColor
    }

    /// WCAG relative luminance of an sRGB colour.
    nonisolated static func luminance(_ c: NSColor) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}

/// Document view that keeps the page horizontally centred and grows with it. Without page edges the whole
/// view is paper; with them, a page sits on the gray canvas with some space above and around it.
final class PageCanvasView: NSView {
    var showsPageEdges = false {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }
    var pageWidth: CGFloat = 612
    /// The left page margin: the page view (the text column) starts this far inside the page.
    var leftMargin: CGFloat = 72
    /// The text column's width when the page fits: the document's text width.
    var columnWidth: CGFloat = 468 {
        didSet { needsLayout = true }
    }
    /// Space around the page when its edges show.
    private var padding: CGFloat { showsPageEdges && !isNarrow ? 32 : 0 }

    /// Narrower than the page, the text wraps to the window with this much room each side (like a note).
    static let narrowInset: CGFloat = 20
    static let minimumColumn: CGFloat = 120
    /// The window is narrower than the page: the column follows the window, and there are no page edges.
    private(set) var isNarrow = false

    /// The white page behind the text column (all of it when narrow).
    var pageRect: NSRect {
        guard let page else { return .zero }
        if isNarrow { return NSRect(x: 0, y: page.frame.minY, width: bounds.width, height: page.frame.height) }
        return NSRect(x: page.frame.minX - leftMargin, y: page.frame.minY, width: pageWidth, height: page.frame.height)
    }

    /// The page's appearance when it differs from the window's (Settings: a light page in Dark Mode).
    var pageAppearance: NSAppearance? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let paper = showsPageEdges ? pageRect.intersection(dirtyRect) : dirtyRect
        (pageAppearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            paper.fill()
        }
    }

    /// Clicks in the page's side margins go to the text.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page, !showsPageEdges || pageRect.contains(point) {
            window?.makeFirstResponder(page)
            page.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    var page: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let page {
                page.postsFrameChangedNotifications = true
                addSubview(page)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(pageFrameChanged), name: NSView.frameDidChangeNotification,
                    object: page)
                needsLayout = true
            }
        }
    }

    override var isFlipped: Bool { true }

    /// Zooming changes the clip view's bounds (not its frame): lay out again to keep the page centred.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        // A resized window changes the clip's frame: narrow or not may change with it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    private var clipWidth: CGFloat = 0
    @objc private func clipBoundsChanged(_ note: Notification) {
        guard let width = superview?.bounds.width, abs(width - clipWidth) > 0.5 else { return }
        clipWidth = width
        needsLayout = true
    }

    @objc private func pageFrameChanged(_ note: Notification) {
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let page, let clip = superview else { return }
        // Rounded down: zoomed, the clip's bounds are fractional, and a canvas a fraction wider than
        // them would bring up a horizontal scroller.
        // The clip's bounds include the space under the title bar and format bar (the scroll view's
        // insets), which the canvas mustn't fill or a short document would scroll.
        let insets =
            (clip.superview as? NSScrollView).map {
                ($0.contentInsets.top + $0.contentInsets.bottom) / $0.magnification
            } ?? 0
        let available = clip.bounds.width.rounded(.down)
        let wasNarrow = isNarrow
        // Narrow means the window itself (its width on screen, whatever the zoom) is narrower than the page:
        // zooming a wide window still magnifies the page and scrolls, as in Google Docs.
        isNarrow = clip.frame.width.rounded(.down) < pageWidth + 2 * (showsPageEdges ? 32 : 0)
        if isNarrow != wasNarrow { needsDisplay = true }
        let column = isNarrow ? max(Self.minimumColumn, available - 2 * Self.narrowInset) : columnWidth
        if abs(page.frame.width - column) > 0.5 {
            page.setFrameSize(NSSize(width: column, height: page.frame.height))
        }
        let width = isNarrow ? max(available, column + 2 * Self.narrowInset) : max(available, pageWidth + 2 * padding)
        let height = max((clip.bounds.height - insets).rounded(.down), page.frame.height + 2 * padding)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        let x = isNarrow ? Self.narrowInset : ((width - pageWidth) / 2).rounded() + leftMargin
        if page.frame.origin != NSPoint(x: x, y: padding) {
            page.setFrameOrigin(NSPoint(x: x, y: padding))
            needsDisplay = true
        }
        (page as? CartillaTextView)?.alignRulerOrigin()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) { needsLayout = true }
}
