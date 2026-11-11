import AppKit
import LibretillaDocx
import PDFKit
import Synchronization
import os

/// A `.docx` document. The file on disk *is* the document (bootstrap §5.4): edits autosave in
/// place, asynchronously, from an immutable snapshot taken on the main thread.
final class LibretillaDocument: NSDocument {
    static let docxType = "org.openxmlformats.wordprocessingml.document"
    nonisolated static let codec: any DocxCodec = OOXMLCodec()
    nonisolated private static let log = Logger(subsystem: "app.libretilla.Libretilla", category: "Document")

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
        let text = AttributedStringBridge(docx).attributedString(for: docx.body)
        loaded.withLock { $0 = Loaded(docx: docx, text: text, originalData: data) }
    }

    /// Moves what `read` produced into main-actor state.
    private func adoptLoaded() {
        guard
            let l = loaded.withLock({ state -> Loaded? in
                defer { state = nil }; return state
            })
        else {
            if base == nil {
                // A new document starts from Libretilla's blank template (one empty paragraph).
                base = Self.emptyDocument
                initialText = AttributedStringBridge(Self.emptyDocument).attributedString(for: Self.emptyDocument.body)
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
        editor?.apply(pageSetup)
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
                    // The file has caught up: the backstop's clock restarts at the next change.
                    if !self.hasUnautosavedChanges { self.firstUnsavedChange = nil }
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
        let result = AttributedStringBridge(snap.base).body(from: snap.text, base: snap.base.body)
        for notice in result.notices { Self.log.notice("\(notice)") }
        var doc = snap.base
        doc.body = result.body
        try Self.codec.write(doc).write(to: url)
    }

    /// ADR 0004: before the first save over a file Libretilla opened, keep a private copy of it.
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
        scheduleAutosaveBackstop()
        if case .saving = saveState { return }
        if !isReadOnly { saveState = isDocumentEdited ? .edited : .saved }
    }

    // MARK: Autosave backstop

    /// How long after a change the file must have caught up. NSDocument normally autosaves about 3 s after it.
    static let autosaveBackstopDelay: TimeInterval = 5
    /// Tests only: drop NSDocument's own scheduled autosave, to check the backstop alone keeps the file current.
    nonisolated(unsafe) static var suppressesScheduledAutosaveForTesting = false
    private var autosaveBackstopPending = false
    /// When the oldest change the file doesn't have yet was made (nil when it's current).
    private var firstUnsavedChange: Date?

    override func scheduleAutosaving() {
        if Self.suppressesScheduledAutosaveForTesting { return }
        super.scheduleAutosaving()
    }

    /// The file on disk is the document (bootstrap §5.4), so an edit must reach it within seconds. NSDocument
    /// schedules an autosave after each change, but that autosave doesn't always run: on GitHub's macOS
    /// runners it never did after Find and Replace ▸ All, whatever happened next. If changes are still
    /// unautosaved this long after the first change since the file was last current, autosave now. Measured
    /// from that first change, not the last, so continuous typing can't postpone it.
    private func scheduleAutosaveBackstop() {
        guard hasUnautosavedChanges, !isReadOnly else {
            firstUnsavedChange = nil
            return
        }
        let first = firstUnsavedChange ?? Date()
        firstUnsavedChange = first
        guard !autosaveBackstopPending else { return }
        autosaveBackstopPending = true
        let due = max(0, Self.autosaveBackstopDelay - Date().timeIntervalSince(first))
        DispatchQueue.main.asyncAfter(deadline: .now() + due) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosaveBackstopPending = false
                guard self.hasUnautosavedChanges, !self.isReadOnly, let first = self.firstUnsavedChange else {
                    self.firstUnsavedChange = nil
                    return
                }
                // An autosave since then made the file current and the clock restarted: not due yet.
                if case .saving = self.saveState {
                    self.scheduleAutosaveBackstop()
                    return
                }
                if Date().timeIntervalSince(first) < Self.autosaveBackstopDelay - 0.05 {
                    self.scheduleAutosaveBackstop()
                    return
                }
                Self.log.notice("The scheduled autosave hasn't run; autosaving now")
                self.autosave(withImplicitCancellability: false) { _ in }
            }
        }
    }

    // MARK: Styles and lists (M2)

    /// Maps the editor's text to and from this document's styles and lists, as they are now.
    var bridge: AttributedStringBridge { AttributedStringBridge(base ?? Self.emptyDocument) }

    /// The id of the paragraph style with this built-in name, copying its definition from Libretilla's
    /// template if the document doesn't have it yet (a Pages file without "heading 3", say).
    func paragraphStyleId(named name: String) -> String? { styleId(named: name, type: "paragraph") }

    /// The id of the character style with this built-in name ("Hyperlink"), copied in like paragraph styles.
    func characterStyleId(named name: String) -> String? { styleId(named: name, type: "character") }

    /// The id of the table style with this built-in name ("Table Grid"), copied in like paragraph styles.
    func tableStyleId(named name: String) -> String? { styleId(named: name, type: "table") }

    private func styleId(named name: String, type: String) -> String? {
        guard var doc = base else { return nil }
        if let id = doc.styles.styleId(named: name, type: type) { return id }
        let template = Self.emptyDocument.styles
        guard let templateId = template.styleId(named: name, type: type),
            let id = doc.styles.ensureStyle(templateId, from: template)
        else { return nil }
        base = doc
        return id
    }

    /// A new list instance in `numbering.xml`.
    func addList(_ kind: Numbering.ListKind) -> Int? {
        guard var doc = base else { return nil }
        // New list items use "List Paragraph" like Word's; make sure it exists.
        if doc.styles.styleId(named: "List Paragraph") == nil {
            let template = Self.emptyDocument.styles
            if let id = template.styleId(named: "List Paragraph") { _ = doc.styles.ensureStyle(id, from: template) }
        }
        let numId = doc.numbering.addList(kind)
        base = doc
        return numId
    }

    /// Replaces the style sheet, undoably (Update Style to Match Selection).
    func setStyles(_ styles: StyleSheet, actionName: String) {
        guard var doc = base else { return }
        let old = doc.styles
        doc.styles = styles
        base = doc
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setStyles(old, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
        editor?.restyleAll()
    }

    // MARK: Page setup (M3)

    /// The page size, orientation and margins, from the document's final `w:sectPr`.
    var pageSetup: PageSetup { base?.body.pageSetup ?? .fallback }

    /// Changes the page setup, undoably. The text is untouched; the next save rewrites only the changed
    /// `w:pgSz` / `w:pgMar` attributes.
    func setPageSetup(_ setup: PageSetup, actionName: String = String(localized: "Page Setup")) {
        guard var doc = base, setup != doc.body.pageSetup else { return }
        let old = doc.body.pageSetup
        doc.body.pageSetup = setup
        base = doc
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setPageSetup(old, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
        editor?.apply(setup)
    }

    // MARK: Headers and footers (M5, ADR 0007)

    var headersFooters: HeadersFooters { base?.headersFooters ?? HeadersFooters() }
    var differentFirstPage: Bool { base?.body.differentFirstPage ?? false }

    /// Replaces the headers and footers and the "Different first page" setting, undoably. The next save writes
    /// the stories that changed and creates parts for new ones.
    func setHeadersFooters(
        _ headersFooters: HeadersFooters, differentFirstPage: Bool,
        actionName: String = String(localized: "Header and Footer")
    ) {
        guard var doc = base else { return }
        let old = (doc.headersFooters, doc.body.differentFirstPage)
        doc.headersFooters = headersFooters
        doc.body.differentFirstPage = differentFirstPage
        base = doc
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setHeadersFooters(old.0, differentFirstPage: old.1, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Printer choice, scaling and other settings from the last Page Setup or Print sheet.
    private var printSettings = NSPrintInfo.shared.copy() as! NSPrintInfo

    /// What File ▸ Page Setup… and printing start from: the document's own paper size, orientation and
    /// margins. Derived, never stored through `super`: NSDocument's setter would count as an edit, so
    /// merely opening a document would mark it edited. Page setup changes are undoable through
    /// `setPageSetup` instead.
    override var printInfo: NSPrintInfo {
        get { Self.printInfo(for: pageSetup, basedOn: printSettings) }
        set { printSettings = newValue.copy() as! NSPrintInfo }
    }

    /// Print settings for `setup`: paper size, orientation and margins as in the document.
    static func printInfo(for setup: PageSetup, basedOn info: NSPrintInfo) -> NSPrintInfo {
        let info = info.copy() as! NSPrintInfo
        let margins = setup.margins
        info.orientation = setup.isLandscape ? .landscape : .portrait
        info.paperSize = setup.pageSize
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// File ▸ Page Setup… changes paper size and orientation; margins stay as the document has them
    /// (the system sheet doesn't edit them).
    override func shouldChangePrintInfo(_ newPrintInfo: NSPrintInfo) -> Bool {
        guard !isReadOnly else { return false }
        setPageSetup(pageSetup.withPaper(newPrintInfo.paperSize, landscape: newPrintInfo.orientation == .landscape))
        return true
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
        editor?.apply(pageSetup)
        editor?.replaceAllUndoably(AttributedStringBridge(docx).attributedString(for: docx.body))
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(restoreOriginal(_:)) { return canRestoreOriginal && !isReadOnly }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws
        -> NSPrintOperation
    {
        let parts = printParts()
        guard parts.count > 1 else {
            let part =
                parts.first
                ?? PrintPart(
                    text: initialText, setup: pageSetup, headersFooters: headersFooters,
                    differentFirstPage: differentFirstPage)
            return operation(printing: part, pageOffset: 0, totalPages: nil, settings: printSettings)
        }
        // Sections with their own paper: print the PDF made of each one's pages.
        let info = Self.printInfo(for: pageSetup, basedOn: printInfo)
        info.dictionary().addEntries(from: printSettings)
        guard let op = try sectionedPDF(parts).printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true)
        else { throw CocoaError(.fileWriteUnknown) }
        return op
    }

    /// Text printed on pages of one setup: a section, with any continuous sections after it, and the first
    /// section's headers and footers.
    struct PrintPart {
        var text: NSAttributedString
        var setup: PageSetup
        var headersFooters = HeadersFooters()
        var differentFirstPage = false
    }

    /// The text to print, by section (`AttributedStringBridge.sections`). A section that starts on a new page
    /// (or an odd or even one) starts a part; a continuous one joins the part before it, on the same pages.
    func printParts() -> [PrintPart] {
        let text = editor?.textSnapshot() ?? initialText
        let sections = AttributedStringBridge.sections(in: text, last: pageSetup)
        let decorations = headersFooters.bySection(sections, differentFirstPage: differentFirstPage)
        var parts: [(range: NSRange, part: PrintPart)] = []
        for (section, decoration) in zip(sections, decorations) {
            if let last = parts.indices.last, [.continuous, .nextColumn].contains(section.setup.start) {
                parts[last].range = NSUnionRange(parts[last].range, section.range)
            } else {
                let part = PrintPart(
                    text: NSAttributedString(), setup: section.setup, headersFooters: decoration.headersFooters,
                    differentFirstPage: decoration.differentFirstPage)
                parts.append((section.range, part))
            }
        }
        let ns = text.string as NSString
        return parts.map { range, part in
            var r = range
            // A section's last paragraph mark would add an empty line, and maybe an empty page.
            if r.length > 1, NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r) - 1) == 0x0A { r.length -= 1 }
            var part = part
            part.text = text.attributedSubstring(from: r)
            return part
        }
    }

    /// The print operation for one part: its paper size and margins, its headers and footers numbered from
    /// `pageOffset + 1` out of `totalPages` (or the part's own count).
    private func operation(
        printing part: PrintPart, pageOffset: Int, totalPages: Int?, settings: [NSPrintInfo.AttributeKey: Any]
    ) -> NSPrintOperation {
        let info = Self.printInfo(for: part.setup, basedOn: printInfo)
        info.dictionary().addEntries(from: settings)
        let view = PrintTextView(text: part.text, width: part.setup.textWidth)
        if !part.headersFooters.stories.isEmpty {
            let decorations = PrintTextView.Decorations(
                headersFooters: part.headersFooters, differentFirstPage: part.differentFirstPage, bridge: bridge,
                setup: part.setup, pageOffset: pageOffset, totalPages: totalPages)
            view.decorations = decorations
            (info.topMargin, info.bottomMargin) = PrintTextView.margins(clearing: decorations)
        }
        return NSPrintOperation(view: view, printInfo: info)
    }

    /// The document as a PDF, each part on its own paper. An odd- or even-page section gets a blank page before it
    /// when it would start on the wrong side, as in Word. Headers and footers need the page count, so with them
    /// the parts are laid out twice.
    func sectionedPDF(_ parts: [PrintPart]) throws -> PDFDocument {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-print-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let passes = parts.contains { !$0.headersFooters.stories.isEmpty } ? 2 : 1
        var total: Int?
        var pdf = PDFDocument()
        for _ in 0..<passes {
            pdf = PDFDocument()
            for (i, part) in parts.enumerated() {
                let nextPage = pdf.pageCount + 1
                let wrongSide =
                    switch part.setup.start {
                    case .evenPage: nextPage % 2 == 1
                    case .oddPage: nextPage % 2 == 0
                    default: false
                    }
                if wrongSide, pdf.pageCount > 0 {
                    let blank = PDFPage()
                    blank.setBounds(NSRect(origin: .zero, size: part.setup.pageSize), for: .mediaBox)
                    pdf.insert(blank, at: pdf.pageCount)
                }
                let url = scratch.appendingPathComponent("\(i).pdf")
                let op = operation(
                    printing: part, pageOffset: pdf.pageCount, totalPages: total,
                    settings: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: url])
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                guard op.run(), let pages = PDFDocument(url: url) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
                }
                for p in 0..<pages.pageCount {
                    if let page = pages.page(at: p) { pdf.insert(page, at: pdf.pageCount) }
                }
            }
            total = pdf.pageCount
        }
        return pdf
    }

    // MARK: PDF export (M3)

    /// File ▸ Export as PDF…: asks where, then writes the PDF.
    @objc func exportPDF(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".pdf"
        panel.canSelectHiddenExtension = true
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self, let url = panel.url else { return }
                do {
                    try self.writePDF(to: url)
                } catch {
                    self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
        }
    }

    /// Writes the document as a PDF, paginated with each section's own paper size and margins.
    func writePDF(to url: URL, showsProgress: Bool = true) throws {
        let parts = printParts()
        if parts.count > 1 {
            guard try sectionedPDF(parts).write(to: url) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
            }
            return
        }
        let op = try printOperation(withSettings: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        op.showsPrintPanel = false
        op.showsProgressPanel = showsProgress
        guard op.run() else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
    }

    // MARK: New documents

    static let emptyBridge = AttributedStringBridge(emptyDocument)

    /// The package a new document starts from: Libretilla's minimal valid `.docx`.
    static let emptyDocument: DocxDocument = {
        guard let url = Bundle.main.url(forResource: "Blank", withExtension: "docx"),
            let data = try? Data(contentsOf: url), let doc = try? codec.read(data)
        else { fatalError("Blank.docx missing from the app bundle") }
        return doc
    }()
}
