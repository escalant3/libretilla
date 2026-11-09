import AppKit
import LibretillaDocx

/// Format ▸ Header and Footer… (ADR 0007).
extension EditorViewController {
    @objc func editHeaderAndFooter(_ sender: Any?) {
        guard textView.isEditable, let document, let window = view.window else { return NSSound.beep() }
        // New headers and footers use the document's "header" and "footer" styles, as Word's do. A document without
        // them (rare: Word and Libretilla's template have both) gets plain paragraphs; opening the sheet and
        // cancelling must not change the document.
        var styleIds: [HeadersFooters.Kind: String] = [:]
        for kind in HeadersFooters.Kind.allCases {
            styleIds[kind] = bridge.styles.styleId(named: kind.styleName)
        }
        let editor = HeaderFooterSheet(
            headersFooters: document.headersFooters, differentFirstPage: document.differentFirstPage,
            bridge: bridge, styleIds: styleIds)
        editor.onDone = { [weak document] headersFooters, differentFirstPage in
            document?.setHeadersFooters(headersFooters, differentFirstPage: differentFirstPage)
        }
        headerFooterEditor = editor
        editor.present(on: window) { [weak self] in
            guard let self else { return }
            self.headerFooterEditor = nil
            self.view.window?.makeFirstResponder(self.textView)
        }
    }
}
