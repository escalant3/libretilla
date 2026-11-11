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
        let formatter = PictureFormatSheet(format: picture.format, naturalSize: picture.naturalSize)
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
        formatter.present(on: window) { [weak self] in
            self?.pictureFormatter = nil
            self.map { $0.view.window?.makeFirstResponder($0.textView) }
        }
    }

    // MARK: Resize handles (backlog 12)

    /// Shows the handles on the selected picture, or hides them.
    func updatePictureHandles() {
        let selection = textView.selectedRange()
        guard textView.isEditable, pictureFormatter == nil, selection.length == 1,
            let storage = textView.textStorage,
            let picture = bridge.editablePicture(in: storage, at: selection.location),
            let frame = pictureFrame(at: selection.location)
        else {
            pictureHandles.removeFromSuperview()
            return
        }
        if pictureHandles.superview !== textView { textView.addSubview(pictureHandles) }
        pictureHandles.cornersOnly = picture.format.rotation != 0
        pictureHandles.pictureFrame = frame
        pictureHandles.window?.invalidateCursorRects(for: pictureHandles)
        let original = storage.attribute(.attachment, at: picture.range.location, effectiveRange: nil)
        let shown = frame.size
        // A drag sizes what's shown (the turned picture's bounding box); the picture's own size scales with it.
        func format(for size: CGSize) -> PictureFormat {
            var format = picture.format
            if format.rotation == 0 {
                format.size = size
            } else {
                let scale = size.width / max(1, shown.width)
                format.size = CGSize(width: format.size.width * scale, height: format.size.height * scale)
            }
            return format
        }
        pictureHandles.onDrag = { [weak self] size in
            guard let self else { return }
            self.previewPicture(picture, format: format(for: size))
            if let frame = self.pictureFrame(at: picture.range.location) { self.pictureHandles.pictureFrame = frame }
        }
        pictureHandles.onEnd = { [weak self] size in
            guard let self else { return }
            if let original { self.showAttachment(original, at: picture.range) }
            if let size { self.applyPicture(picture, format: format(for: size)) }
            self.updatePictureHandles()
        }
    }

    /// Where the picture at `index` is drawn, in the text view's coordinates.
    func pictureFrame(at index: Int) -> CGRect? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index),
            let range = NSTextRange(
                location: content.documentRange.location, end: content.location(location, offsetBy: 1))
        else { return nil }
        // From the start: TextKit 2 only estimates where text it hasn't laid out goes.
        layout.ensureLayout(for: range)
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.frameForTextAttachment(at: location)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        return frame.offsetBy(
            dx: origin.x + textView.textContainerOrigin.x, dy: origin.y + textView.textContainerOrigin.y)
    }

    /// Shows `picture` as `format` without changing what's saved or adding an undo step.
    private func previewPicture(_ picture: AttributedStringBridge.EditablePicture, format: PictureFormat) {
        guard let attachment = bridge.attributes(for: picture, format: format)?[.attachment] else { return }
        showAttachment(attachment, at: picture.range)
    }

    private func showAttachment(_ attachment: Any, at range: NSRange) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        retireAttachments(in: range)
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
