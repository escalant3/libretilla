import AppKit
import CartillaDocx
import Synchronization
import os

/// A `.docx` document. The file on disk *is* the document (bootstrap §5.4): edits autosave in
/// place, asynchronously, from an immutable snapshot taken on the main thread.
final class CartillaDocument: NSDocument {
    static let docxType = "org.openxmlformats.wordprocessingml.document"
    nonisolated static let codec: any DocxCodec = OOXMLCodec()
    nonisolated private static let log = Logger(subsystem: "app.cartilla.Cartilla", category: "Document")

    /// Save state shown next to the title (replaces the Save button and the edited dot).
    enum SaveState: Equatable {
        case saved
        case edited
        case saving
        case failed(String)
        case readOnly(String)
    }

    // MARK: State shared with nonisolated read/write

    /// What `read(from:ofType:)` produced, possibly off the main thread.
    private struct Loaded: @unchecked Sendable {
        var docx: DocxDocument
        var text: NSAttributedString
        var originalData: Data
    }

    /// What a save writes: taken on the main thread, encoded on a background thread.
    private struct Snapshot: @unchecked Sendable {
        var base: DocxDocument
        var text: NSAttributedString
    }

    private let loaded = Mutex<Loaded?>(nil)
    private let snapshot = Mutex<Snapshot?>(nil)

    // MARK: Main-actor state

    /// The document as last read; supplies everything the text doesn't (other parts, section properties).
    private(set) var base: DocxDocument?
    /// Bytes of the file as opened, for the ADR 0004 private copy.
    private var originalData: Data?
    private var keptOriginal = false
    private(set) var saveState: SaveState = .saved {
        didSet { if saveState != oldValue { onSaveStateChange?(saveState) } }
    }
    var onSaveStateChange: ((SaveState) -> Void)?
    /// Set by the window controller; the document's text lives in this view's storage.
    weak var editor: EditorViewController?
    /// Text to show when the editor appears (set by read, consumed by the editor).
    private(set) var initialText = NSAttributedString()

    override class var autosavesInPlace: Bool { true }

    override nonisolated func canAsynchronouslyWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) -> Bool { true }

    override func makeWindowControllers() {
        adoptLoaded()
        addWindowController(DocumentWindowController(document: self))
    }

    var isReadOnly: Bool {
        if case .readOnly = saveState { return true }
        return false
    }

    // MARK: Reading

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let docx = try Self.codec.read(data)
        let text = AttributedStringBridge(styles: docx.styles).attributedString(for: docx.body)
        loaded.withLock { $0 = Loaded(docx: docx, text: text, originalData: data) }
    }

    /// Moves what `read` produced into main-actor state.
    private func adoptLoaded() {
        guard let l = loaded.withLock({ state -> Loaded? in defer { state = nil }; return state }) else {
            if base == nil {
                // A new document starts from Cartilla's blank template (one empty paragraph).
                base = Self.emptyDocument
                initialText = AttributedStringBridge(styles: Self.emptyDocument.styles)
                    .attributedString(for: Self.emptyDocument.body)
            }
            return
        }
        base = l.docx
        originalData = l.originalData
        initialText = l.text
        if let reason = l.docx.readOnlyReason {
            saveState = .readOnly(reason)
        } else {
            saveState = .saved
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        adoptLoaded()
        editor?.show(initialText, editable: !isReadOnly)
    }

    // MARK: Writing

    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let text = editor?.textSnapshot() ?? initialText
        let base = self.base ?? Self.emptyDocument
        snapshot.withLock { $0 = Snapshot(base: base, text: text) }
        keepOriginalIfNeeded(writingTo: url, operation: saveOperation)
        saveState = .saving
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    Self.log.error("Save failed: \(error.localizedDescription)")
                    self.saveState = .failed(error.localizedDescription)
                } else {
                    self.saveState = self.isDocumentEdited ? .edited : .saved
                }
            }
            completionHandler(error)
        }
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        guard let snap = snapshot.withLock({ $0 }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        unblockUserInteraction()
        let result = AttributedStringBridge(styles: snap.base.styles).body(from: snap.text, base: snap.base.body)
        for notice in result.notices { Self.log.notice("\(notice)") }
        var doc = snap.base
        doc.body = result.body
        try Self.codec.write(doc).write(to: url)
    }

    /// ADR 0004: before the first save over a file Cartilla opened, keep a private copy of it.
    private func keepOriginalIfNeeded(writingTo url: URL, operation: NSDocument.SaveOperationType) {
        guard !keptOriginal, let originalData, let fileURL, url.standardizedFileURL == fileURL.standardizedFileURL,
            operation == .autosaveInPlaceOperation || operation == .saveOperation
        else { return }
        do {
            try OriginalsStore.shared.keepOriginal(originalData, of: fileURL)
            keptOriginal = true
        } catch {
            Self.log.error("Couldn't keep the original: \(error.localizedDescription)")
        }
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if case .saving = saveState { return }
        if !isReadOnly { saveState = isDocumentEdited ? .edited : .saved }
    }

    // MARK: Restore Original (ADR 0004)

    var canRestoreOriginal: Bool {
        fileURL.flatMap { OriginalsStore.shared.latestOriginal(of: $0) } != nil
    }

    @objc func restoreOriginal(_ sender: Any?) {
        guard let fileURL, let (_, url) = OriginalsStore.shared.latestOriginal(of: fileURL),
            let data = try? Data(contentsOf: url), let docx = try? Self.codec.read(data)
        else {
            NSSound.beep()
            return
        }
        base = docx
        editor?.replaceAllUndoably(AttributedStringBridge(styles: docx.styles).attributedString(for: docx.body))
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(restoreOriginal(_:)) { return canRestoreOriginal && !isReadOnly }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws
        -> NSPrintOperation
    {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(editor?.textSnapshot() ?? initialText)
        view.sizeToFit()
        return NSPrintOperation(view: view, printInfo: info)
    }

    // MARK: New documents

    /// The package a new document starts from: Cartilla's minimal valid `.docx`.
    static let emptyDocument: DocxDocument = {
        guard let url = Bundle.main.url(forResource: "Blank", withExtension: "docx"),
            let data = try? Data(contentsOf: url), let doc = try? codec.read(data)
        else { fatalError("Blank.docx missing from the app bundle") }
        return doc
    }()
}
