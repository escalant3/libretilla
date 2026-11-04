import AppKit
import CartillaDocx
import os

/// A page-width text column on a quiet canvas (bootstrap §5.1 "page view", stage 1).
/// True pagination is a v1.1 milestone.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    /// US Letter width in points; becomes document-driven in M3 (page setup).
    static let pageWidth: CGFloat = 612
    static let pageMargin: CGFloat = 72

    private(set) var textView: NSTextView!
    nonisolated(unsafe) private var fallbackObserver: (any NSObjectProtocol)?
    nonisolated private static let log = Logger(subsystem: "app.cartilla.Cartilla", category: "Editor")

    deinit {
        if let fallbackObserver { NotificationCenter.default.removeObserver(fallbackObserver) }
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = true

        let canvas = PageCanvasView()
        canvas.pageWidth = Self.pageWidth
        scrollView.documentView = canvas

        // TextKit 2, deliberately (ADR 0001). Never touch `textView.layoutManager`: it forces a
        // permanent fallback to TextKit 1. Known TK2 gaps: docs/TEXTKIT2_GAPS.md.
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: 792)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.textContainerInset = NSSize(width: Self.pageMargin, height: Self.pageMargin)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: Self.pageWidth, height: 792)
        textView.maxSize = NSSize(width: Self.pageWidth, height: .greatestFiniteMagnitude)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(String(localized: "Document body"))
        textView.delegate = self
        canvas.page = textView
        self.textView = textView
        fallbackObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main
        ) { _ in
            // Something forced TextKit 1. Record it as a new gap in docs/TEXTKIT2_GAPS.md.
            Self.log.fault("NSTextView fell back to TextKit 1")
        }
        view = scrollView
    }

    // MARK: Content

    /// Replaces the content without registering an undo action or marking the document edited
    /// (opening a file must never rewrite it).
    func show(_ text: NSAttributedString, editable: Bool) {
        loadViewIfNeeded()
        textView.textStorage?.setAttributedString(text)
        textView.isEditable = editable
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
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

    // MARK: NSTextViewDelegate

    /// Content Cartilla only preserves (links, fields, objects, tables) is edited whole or not at all.
    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        guard let storage = textView.textStorage else { return true }
        return Self.editIsAllowed(affectedCharRange, in: storage)
    }

    /// Typed text never joins a link, field or object, nor copies its markers.
    func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = newTypingAttributes
        for key in NSAttributedString.Key.cartillaNonInheritable { attrs[key] = nil }
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

/// Document view that keeps the page horizontally centred and grows with it.
final class PageCanvasView: NSView {
    var pageWidth: CGFloat = 612
    private let verticalPadding: CGFloat = 32

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

    @objc private func pageFrameChanged(_ note: Notification) { needsLayout = true }

    override func layout() {
        super.layout()
        guard let page, let clip = superview else { return }
        let width = max(clip.bounds.width, pageWidth + 2 * verticalPadding)
        let height = max(clip.bounds.height, page.frame.height + 2 * verticalPadding)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        let x = ((width - pageWidth) / 2).rounded()
        if page.frame.origin != NSPoint(x: x, y: verticalPadding) {
            page.setFrameOrigin(NSPoint(x: x, y: verticalPadding))
        }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) { needsLayout = true }
}
