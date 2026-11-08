import AppKit
import LibretillaDocx
import UniformTypeIdentifiers

/// Insert ▸ Image…, and pictures that arrive by paste or drop (M3).
extension EditorViewController {
    /// New pictures (not the document's own, which keep their Word size) are scaled down to the text width.
    func fitNewPictures(in storage: NSTextStorage, range: NSRange) {
        let column = pageSetup.textWidth
        storage.enumerateAttribute(.attachment, in: range) { value, r, _ in
            guard let attachment = value as? NSTextAttachment,
                storage.attribute(.libretillaOpaque, at: r.location, effectiveRange: nil) == nil,
                storage.attribute(.libretillaPageBreak, at: r.location, effectiveRange: nil) == nil,
                storage.attribute(.libretillaBlock, at: r.location, effectiveRange: nil) == nil
            else { return }
            let size =
                attachment.bounds.width > 0
                ? attachment.bounds.size
                : (attachment.image?.size
                    ?? (attachment.contents ?? attachment.fileWrapper?.regularFileContents).flatMap {
                        NSImage(data: $0)?.size
                    } ?? .zero)
            guard size.width > 0, size.height > 0 else { return }
            let fitted = AttributedStringBridge.fitted(size, maxWidth: column)
            if attachment.bounds.size != fitted { attachment.bounds = NSRect(origin: .zero, size: fitted) }
        }
    }

    @objc func insertImage(_ sender: Any?) {
        guard textView.isEditable, let window = view.window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self, let url = panel.url else { return }
                do {
                    try self.insertImage(contentsOf: url)
                } catch {
                    self.presentError(error)
                }
                self.view.window?.makeFirstResponder(self.textView)
            }
        }
    }

    /// Inserts the image file at `url` at the selection, at most as wide as the text.
    func insertImage(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard
            let picture = AttributedStringBridge.picture(
                data: data, filename: url.lastPathComponent, maxWidth: pageSetup.textWidth,
                attributes: textView.typingAttributes)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        textView.insertText(picture, replacementRange: textView.selectedRange())
        textView.undoManager?.setActionName(String(localized: "Image"))
    }
}

/// Format ▸ Picture… (also a double-click on a picture, or its contextual menu): size, rotation,
/// brightness, contrast and opacity, shown as they change and applied as one undo step.
extension EditorViewController {
    func isPicture(at index: Int) -> Bool {
        guard let storage = textView.textStorage else { return false }
        return bridge.editablePicture(in: storage, at: index) != nil
    }

    /// The picture a Format ▸ Picture… item acts on: the one its contextual menu was opened on, the one
    /// selected, or the one just before (or after) the caret.
    func pictureIndex(for sender: Any?) -> Int? {
        if let index = (sender as? NSMenuItem)?.representedObject as? Int {
            return isPicture(at: index) ? index : nil
        }
        let selection = textView.selectedRange()
        if selection.length == 1 { return isPicture(at: selection.location) ? selection.location : nil }
        guard selection.length == 0 else { return nil }
        return [selection.location - 1, selection.location].first { isPicture(at: $0) }
    }

    @objc func formatPicture(_ sender: Any?) {
        guard let index = pictureIndex(for: sender) else { return NSSound.beep() }
        openPictureFormatter(at: index)
    }

    func openPictureFormatter(at index: Int) {
        guard textView.isEditable, pictureFormatter == nil, let window = view.window,
            let storage = textView.textStorage,
            let picture = bridge.editablePicture(in: storage, at: index)
        else { return NSSound.beep() }
        textView.setSelectedRange(picture.range)
        let original = storage.attribute(.attachment, at: index, effectiveRange: nil)
        let formatter = PictureFormatController(format: picture.format, naturalSize: picture.naturalSize)
        formatter.onChange = { [weak self] format in
            self?.previewPicture(picture, format: format)
        }
        formatter.onDone = { [weak self] format in
            guard let self else { return }
            // Put back what was shown before (previews aren't edits), then make the change undoably.
            if let original { self.showAttachment(original, at: picture.range) }
            if let format { self.applyPicture(picture, format: format) }
        }
        pictureFormatter = formatter
        window.beginSheet(formatter.window!) { [weak self] _ in
            self?.pictureFormatter = nil
            self.map { $0.view.window?.makeFirstResponder($0.textView) }
        }
    }

    /// Shows `picture` as `format` without changing what's saved or adding an undo step.
    private func previewPicture(_ picture: AttributedStringBridge.EditablePicture, format: PictureFormat) {
        guard let attachment = bridge.attributes(for: picture, format: format)?[.attachment] else { return }
        showAttachment(attachment, at: picture.range)
    }

    private func showAttachment(_ attachment: Any, at range: NSRange) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.addAttribute(.attachment, value: attachment, range: range)
        storage.endEditing()
    }

    /// Formats `picture` as one undoable change.
    func applyPicture(_ picture: AttributedStringBridge.EditablePicture, format: PictureFormat) {
        guard let storage = textView.textStorage, NSMaxRange(picture.range) <= storage.length,
            let attrs = bridge.attributes(for: picture, format: format)
        else { return NSSound.beep() }
        // Its own undo step, even right after inserting the picture (typing undo would take it in).
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: picture.range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttributes(attrs, range: picture.range)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Format Picture"))
    }

    /// Adds Format Picture… to the contextual menu of a picture.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let hit = view.characterIndex(for: NSEvent.mouseLocation)
        guard view === textView, view.isEditable, hit != NSNotFound, isPicture(at: hit) else { return menu }
        let item = NSMenuItem(
            title: String(localized: "Format Picture…"), action: #selector(formatPicture(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = hit
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}
