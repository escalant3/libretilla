import AppKit
import LibretillaDocx

/// File ▸ Margins…: the page margins, which the system's Page Setup sheet doesn't edit.
extension EditorViewController {
    @objc func editMargins(_ sender: Any?) {
        guard textView.isEditable, marginsEditor == nil, let document, let window = view.window else {
            return NSSound.beep()
        }
        let sheet = MarginsSheet(setup: document.pageSetup)
        sheet.onDone = { [weak document] setup in
            if let setup { document?.setPageSetup(setup, actionName: String(localized: "Margins")) }
        }
        marginsEditor = sheet
        sheet.present(on: window) { [weak self] in
            guard let self else { return }
            self.marginsEditor = nil
            self.view.window?.makeFirstResponder(self.textView)
        }
    }
}
