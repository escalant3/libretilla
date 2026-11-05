import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let editor = EditorViewController()
    private let status = SaveStatusViewController()
    private let formatBar = FormatBarViewController()
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
        window.contentViewController = editor
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
        window.toolbar = MainToolbar.make()
        window.addTitlebarAccessoryViewController(status)
        formatBar.target = editor
        window.addTitlebarAccessoryViewController(formatBar)
        formatBar.isHidden = UserDefaults.standard.bool(forKey: Self.formatBarHiddenKey)
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
        editor.apply(document.pageSetup)
        editor.show(document.initialText, editable: !document.isReadOnly)
        status.show(document.saveState, isDraft: document.fileURL == nil)
        document.onSaveStateChange = { [weak self, weak document] state in
            self?.status.show(state, isDraft: document?.fileURL == nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    func windowDidBecomeMain(_ notification: Notification) {
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
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
