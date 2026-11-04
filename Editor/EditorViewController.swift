import AppKit
import os

/// A page-width text column on a quiet canvas (bootstrap §5.1 "page view", stage 1).
/// True pagination is a v1.1 milestone.
final class EditorViewController: NSViewController {
    /// US Letter width in points; becomes document-driven in M3 (page setup).
    static let pageWidth: CGFloat = 612
    static let pageMargin: CGFloat = 72

    private(set) var textView: NSTextView!
    nonisolated(unsafe) private var fallbackObserver: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "app.cartilla.Cartilla", category: "Editor")

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
