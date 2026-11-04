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
            scrollView.backgroundColor = showsPageEdges ? .underPageBackgroundColor : .textBackgroundColor
        }
    }
    /// Supplies the styles and lists the text is mapped through (formatting commands, saving).
    weak var document: CartillaDocument?
    /// Called (coalesced) when the selection or its formatting changes, for the format bar.
    var onSelectionFormatChange: ((SelectionFormat, AttributedStringBridge) -> Void)?

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
        view = scrollView
        apply(pageSetup)
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
        textView.textContainerInset = NSSize(width: 0, height: margins.top)
        textView.minSize = NSSize(width: column, height: setup.pageSize.height)
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
        guard !isLoading, editedRange.location != NSNotFound else { return }
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

    func textViewDidChangeSelection(_ notification: Notification) { scheduleSelectionUpdate() }

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
    /// Space around the page when its edges show.
    private var padding: CGFloat { showsPageEdges ? 32 : 0 }

    /// The white page behind the text column.
    var pageRect: NSRect {
        guard let page else { return .zero }
        return NSRect(x: page.frame.minX - leftMargin, y: page.frame.minY, width: pageWidth, height: page.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        (showsPageEdges ? pageRect.intersection(dirtyRect) : dirtyRect).fill()
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

    @objc private func pageFrameChanged(_ note: Notification) {
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let page, let clip = superview else { return }
        let width = max(clip.bounds.width, pageWidth + 2 * padding)
        let height = max(clip.bounds.height, page.frame.height + 2 * padding)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        let x = ((width - pageWidth) / 2).rounded() + leftMargin
        if page.frame.origin != NSPoint(x: x, y: padding) {
            page.setFrameOrigin(NSPoint(x: x, y: padding))
            needsDisplay = true
        }
        (page as? CartillaTextView)?.alignRulerOrigin()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) { needsLayout = true }
}
