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
