import AppKit
import SwiftUI

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editor = EditorViewController()
    private let status = SaveStatusViewController()
    private let formatBar = FormatBarViewController()
    private let outline = OutlineModel()
    private let split = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    private var outlineShown = false
    nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?
    static let formatBarHiddenKey = "LibretillaFormatBarHidden"
    static let showsPageEdgesKey = "LibretillaShowsPageEdges"
    static let zoomKey = "LibretillaZoom"
    static let minimumWidth: CGFloat = 320

    /// Wide enough for the whole format bar and a Letter or A4 page, within the screen's visible area.
    static var defaultContentSize: NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        // The title bar, toolbar and format bar sit above the content.
        return NSSize(width: min(1040, visible.width), height: min(1000, max(240, visible.height - 120)))
    }

    init(document: LibretillaDocument) {
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        // The outline is a sidebar beside the editor (View ▸ Show Outline ⌃⌘S), hidden by default.
        let sidebar = NSHostingController(rootView: OutlineSidebar(model: outline))
        sidebar.sizingOptions = []
        sidebar.view.setAccessibilityLabel(String(localized: "Outline"))
        let outlineItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        outlineItem.minimumThickness = 180
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true
        // In a narrow window the outline gets out of the text's way, as sidebars do in Mail and Notes.
        outlineItem.canCollapseFromWindowResize = true
        split.addSplitViewItem(outlineItem)
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = Self.minimumWidth
        split.addSplitViewItem(editorItem)
        // The sidebar's width is remembered; whether it shows is Libretilla's own setting (set after the split
        // view restores its saved state).
        split.splitView.autosaveName = "LibretillaOutlineSplit"
        outlineShown = UserDefaults.standard.bool(forKey: Preferences.outlineShownKey)
        outlineItem.isCollapsed = !outlineShown
        window.contentViewController = split
        // Assigning a content view controller sizes the window to the view's fitting size, which is
        // zero for a scroll view: set the real size afterwards.
        // Thin enough to sit beside a video call for notes: the format bar overflows, the text rewraps.
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: 240)
        window.setContentSize(Self.defaultContentSize)
        // Setting the autosave name restores the saved frame, if any; reject frames that are too small.
        let restored =
            window.setFrameAutosaveName("LibretillaDocumentWindow")
            && window.setFrameUsingName("LibretillaDocumentWindow")
        let minimum = window.contentMinSize
        if !restored || window.contentLayoutRect.width < minimum.width
            || window.contentLayoutRect.height < minimum.height
        {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        Self.fitOnScreen(window)
        window.toolbar = MainToolbar.make()
        window.addTitlebarAccessoryViewController(status)
        formatBar.target = editor
        window.addTitlebarAccessoryViewController(formatBar)
        formatBar.isHidden = UserDefaults.standard.bool(forKey: Self.formatBarHiddenKey)
        self.outlineItem = outlineItem
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        document.editor = editor
        editor.document = document
        editor.onSelectionFormatChange = { [weak self] format, bridge in
            guard let self else { return }
            self.formatBar.update(format, bridge: bridge, editable: self.editor.textView.isEditable)
        }
        editor.showsPageEdges = UserDefaults.standard.bool(forKey: Self.showsPageEdgesKey)
        // The zoom is remembered for every window, like page edges. 0 (or nothing saved) is Fit, the default.
        editor.onZoomChange = { [weak self] zoom, fits in
            // Fit follows every resize: only write when the setting changes (each write refreshes every window).
            let saved = fits ? 0 : Double(zoom)
            if UserDefaults.standard.object(forKey: Self.zoomKey) as? Double != saved {
                UserDefaults.standard.set(saved, forKey: Self.zoomKey)
            }
            self?.formatBar.showZoom(zoom, fits: fits)
        }
        outline.onSelect = { [weak self] heading in self?.editor.go(to: heading) }
        editor.onHeadingsChange = { [weak self] headings in
            guard let self else { return }
            self.outline.show(headings)
            self.outline.followCaret(at: self.editor.textView.selectedRange().location)
        }
        editor.onCaretMove = { [weak self] location in self?.outline.followCaret(at: location) }
        applyPreferences()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        editor.apply(document.pageSetup)
        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        if savedZoom > 0 { editor.zoom = savedZoom } else { editor.zoomToFit(nil) }
        editor.show(document.initialText, editable: !document.isReadOnly)
        status.show(document.saveState, isDraft: document.fileURL == nil)
        document.onSaveStateChange = { [weak self, weak document] state in
            self?.status.show(state, isDraft: document?.fileURL == nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keeps the whole window on the screen's visible area. AppKit only pulls a window's top edge back on
    /// screen, so the default size plus the outline sidebar ran off the right of a 1024-point display.
    static func fitOnScreen(_ window: NSWindow) {
        if let frame = onScreenFrame(for: window), frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// `window`'s frame moved and shrunk to lie within its screen's visible area.
    static func onScreenFrame(for window: NSWindow) -> NSRect? {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame, !visible.isEmpty else { return nil }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Applies Settings (and the View menu's remembered choices) to this window. Called for every defaults
    /// change, so it only touches what differs.
    func applyPreferences() {
        editor.loadViewIfNeeded()
        let defaults = UserDefaults.standard
        let light = Preferences.keepsPageLight
        if editor.keepsPageLight != light { editor.keepsPageLight = light }
        let edges = defaults.bool(forKey: Self.showsPageEdgesKey)
        if editor.showsPageEdges != edges { editor.showsPageEdges = edges }
        let barHidden = defaults.bool(forKey: Self.formatBarHiddenKey)
        if formatBar.isHidden != barHidden { formatBar.isHidden = barHidden }
        editor.textView.applyRulerUnits()
    }

    /// AppKit's own reference to the document is neither retained nor zeroed when it goes, so a window that outlived
    /// its document (one that was never closed) crashed reading it, for example validating its toolbar (backlog 36).
    /// This one is weak.
    private weak var currentDocument: AnyObject?

    override var document: AnyObject? {
        get { currentDocument }
        set {
            super.document = newValue
            currentDocument = newValue
            if let doc = newValue as? LibretillaDocument {
                status.show(doc.saveState, isDraft: doc.fileURL == nil)
            }
        }
    }

    /// Text edits register with the document's undo manager, which is what marks it edited.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    /// The window can grow after it's made (shown as a tab of a wider window, the outline sidebar opening);
    /// keep it on screen whenever it's shown or resized.
    func windowDidResize(_ notification: Notification) { scheduleFitOnScreen() }

    private var fitScheduled = false
    /// The frame the last fit asked for; if the window kept a different one (its minimum size), don't insist.
    private var lastFitTarget: NSRect?

    /// Fits on the next turn of the run loop: resizing from inside a resize or layout pass makes AppKit abort
    /// ("needs another update constraints pass").
    private func scheduleFitOnScreen() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            guard let window = self.window, let target = Self.onScreenFrame(for: window), target != window.frame,
                target != self.lastFitTarget
            else { return }
            self.lastFitTarget = target
            window.setFrame(target, display: true)
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        scheduleFitOnScreen()
        window?.makeFirstResponder(editor.textView)
    }

    // MARK: Format bar

    @objc func toggleFormatBar(_ sender: Any?) {
        formatBar.isHidden.toggle()
        UserDefaults.standard.set(formatBar.isHidden, forKey: Self.formatBarHiddenKey)
    }

    /// View ▸ Show/Hide Page Edges; remembered for every window.
    @objc func togglePageEdges(_ sender: Any?) {
        editor.showsPageEdges.toggle()
        UserDefaults.standard.set(editor.showsPageEdges, forKey: Self.showsPageEdgesKey)
    }

    /// View ▸ Show/Hide Outline (⌃⌘S); remembered for new windows.
    /// The split view restores its saved state (sidebar width, and whether it was collapsed) when it first
    /// appears, after `init` applied Libretilla's own setting: an outline hidden in View ▸ Show Outline could come
    /// back open, with the menu still saying "Show Outline". Whether it shows is Libretilla's setting; apply it
    /// again once the window is up.
    override func showWindow(_ sender: Any?) {
        applyOutlineSetting()
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in self?.applyOutlineSetting() }
        scheduleFitOnScreen()
    }

    private func applyOutlineSetting() {
        guard outlineItem.isCollapsed == outlineShown else { return }
        outlineItem.isCollapsed = !outlineShown
        if outlineShown { editor.updateOutline() }
    }

    @objc func toggleOutline(_ sender: Any?) {
        outlineShown.toggle()
        if outlineShown { editor.updateOutline() }
        outlineItem.animator().isCollapsed = !outlineShown
        UserDefaults.standard.set(outlineShown, forKey: Preferences.outlineShownKey)
    }

    var isOutlineShown: Bool { outlineShown }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleOutline(_:)) {
            item.title = isOutlineShown ? String(localized: "Hide Outline") : String(localized: "Show Outline")
        }
        if item.action == #selector(togglePageEdges(_:)) {
            item.title =
                editor.showsPageEdges ? String(localized: "Hide Page Edges") : String(localized: "Show Page Edges")
        }
        if item.action == #selector(toggleFormatBar(_:)) {
            item.title =
                formatBar.isHidden ? String(localized: "Show Format Bar") : String(localized: "Hide Format Bar")
        }
        return true
    }
}

/// Autosave makes the "edited" dot noise; the status label says whether the file is current instead
/// (bootstrap §6: no edited dot, no Save button). AppKit's "Edited" subtitle is NSDocument's Versions state
/// and doesn't come from this flag; it stays, as in TextEdit (owner's decision, 2026-11-05).
final class DocumentWindow: NSWindow {
    override var isDocumentEdited: Bool {
        get { false }
        set {}
    }
}
