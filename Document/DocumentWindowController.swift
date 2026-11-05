import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editor = EditorViewController()
    private let status = SaveStatusViewController()
    private let formatBar = FormatBarViewController()
    private let outline = OutlineViewController()
    private let split = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    private var outlineShown = false
    nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?
    static let formatBarHiddenKey = "CartillaFormatBarHidden"
    static let showsPageEdgesKey = "CartillaShowsPageEdges"
    static let zoomKey = "CartillaZoom"

    init(document: CartillaDocument) {
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        // The outline is a sidebar beside the editor (View ▸ Show Outline ⌃⌘S), hidden by default.
        let outlineItem = NSSplitViewItem(sidebarWithViewController: outline)
        outlineItem.minimumThickness = 180
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true
        split.addSplitViewItem(outlineItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: editor))
        // The sidebar's width is remembered; whether it shows is Cartilla's own setting (set after the split
        // view restores its saved state).
        split.splitView.autosaveName = "CartillaOutlineSplit"
        outlineShown = UserDefaults.standard.bool(forKey: Preferences.outlineShownKey)
        outlineItem.isCollapsed = !outlineShown
        window.contentViewController = split
        // Assigning a content view controller sizes the window to the view's fitting size, which is
        // zero for a scroll view: set the real size afterwards.
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 900, height: 1000))
        // Setting the autosave name restores the saved frame, if any; reject frames that are too small.
        let restored =
            window.setFrameAutosaveName("CartillaDocumentWindow") && window.setFrameUsingName("CartillaDocumentWindow")
        let minimum = window.contentMinSize
        if !restored || window.contentLayoutRect.width < minimum.width
            || window.contentLayoutRect.height < minimum.height
        {
            window.setContentSize(NSSize(width: 900, height: 1000))
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
        // The zoom is remembered for every window, like page edges.
        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        editor.zoom = savedZoom > 0 ? savedZoom : 1
        formatBar.showZoom(editor.zoom)
        editor.onZoomChange = { [weak self] zoom in
            UserDefaults.standard.set(Double(zoom), forKey: Self.zoomKey)
            self?.formatBar.showZoom(zoom)
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
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame, !visible.isEmpty else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
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

    override var document: AnyObject? {
        didSet {
            if let doc = document as? CartillaDocument {
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
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window { Self.fitOnScreen(window) }
    }

    func windowDidResize(_ notification: Notification) {
        if let window { Self.fitOnScreen(window) }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        if let window { Self.fitOnScreen(window) }
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

/// Autosave makes the "edited" dot and "— Edited" title noise; the status label says it instead
/// (bootstrap §6: no edited dot, no Save button).
final class DocumentWindow: NSWindow {
    override var isDocumentEdited: Bool {
        get { false }
        set {}
    }
}
