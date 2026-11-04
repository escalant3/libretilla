import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private let editor = EditorViewController()
    private let status = SaveStatusViewController()

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
        let restored = window.setFrameAutosaveName("CartillaDocumentWindow") && window.setFrameUsingName("CartillaDocumentWindow")
        let minimum = window.contentMinSize
        if !restored || window.contentLayoutRect.width < minimum.width
            || window.contentLayoutRect.height < minimum.height
        {
            window.setContentSize(NSSize(width: 900, height: 1000))
            window.center()
        }
        window.toolbar = MainToolbar.make()
        window.addTitlebarAccessoryViewController(status)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        document.editor = editor
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
}

/// Autosave makes the "edited" dot and "— Edited" title noise; the status label says it instead
/// (bootstrap §6: no edited dot, no Save button).
final class DocumentWindow: NSWindow {
    override var isDocumentEdited: Bool {
        get { false }
        set {}
    }
}
