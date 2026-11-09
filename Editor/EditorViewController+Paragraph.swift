import AppKit
import LibretillaDocx

/// Format ▸ Paragraph…: exact alignment, indents and spacing for the selected paragraphs.
extension EditorViewController {
    @objc func formatParagraph(_ sender: Any?) {
        guard textView.isEditable, paragraphEditor == nil, let window = view.window,
            let storage = textView.textStorage, storage.length > 0,
            let first = AttributedStringBridge.paragraphRanges(in: storage, touching: textView.selectedRange()).first
        else { return NSSound.beep() }
        let direct = AttributedStringBridge.paragraphFormatOf(storage, first)?.properties ?? ParagraphProperties()
        let sheet = ParagraphSheet(paragraph: bridge.effectiveParagraph(direct))
        sheet.onDone = { [weak self] changes in
            guard let self, let changes else { return }
            self.editParagraphs(changes, actionName: String(localized: "Paragraph"))
        }
        paragraphEditor = sheet
        sheet.present(on: window) { [weak self] in
            guard let self else { return }
            self.paragraphEditor = nil
            self.view.window?.makeFirstResponder(self.textView)
        }
    }
}
