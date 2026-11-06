import AppKit
import LibretillaDocx

/// Insert ▸ Link… (⌘K) and following links (M3).
extension EditorViewController {
    /// The link a caret sits strictly inside (not at its start or end), if any.
    func linkAround(caret: NSRange, in text: NSAttributedString) -> (range: NSRange, box: HyperlinkBox)? {
        guard caret.length == 0, caret.location > 0, caret.location < text.length,
            let link = AttributedStringBridge.link(at: caret.location, in: text),
            caret.location > link.range.location, caret.location < NSMaxRange(link.range)
        else { return nil }
        return link
    }

    /// Adds, changes or removes a link: on the selection, or on the whole link the caret is in. With a bare
    /// caret outside any link it asks for the text too and inserts it.
    @objc func editLink(_ sender: Any?) {
        guard textView.isEditable, let storage = textView.textStorage, let window = view.window else {
            return NSSound.beep()
        }
        let selection = textView.selectedRange()
        let existing = AttributedStringBridge.link(at: selection.location, in: storage).flatMap { link in
            // A selection inside one link, or a caret touching it, edits that link.
            NSLocationInRange(selection.location, link.range) || selection.location == NSMaxRange(link.range)
                ? link : nil
        }
        let target = existing?.range ?? selection
        let needsText = target.length == 0

        let alert = NSAlert()
        alert.messageText = existing == nil ? String(localized: "Add Link") : String(localized: "Edit Link")
        let urlField = NSTextField(string: existing?.box.url?.absoluteString ?? "")
        urlField.placeholderString = "https://"
        let textField = NSTextField(string: "")
        textField.placeholderString = String(localized: "Text to show")
        let stack = NSStackView(views: needsText ? [textField, urlField] : [urlField])
        stack.orientation = .vertical
        stack.alignment = .leading
        for field in stack.arrangedSubviews { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: needsText ? 56 : 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: existing == nil ? String(localized: "Add Link") : String(localized: "Update Link"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if existing != nil { alert.addButton(withTitle: String(localized: "Remove Link")) }
        alert.window.initialFirstResponder = needsText ? textField : urlField

        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    guard let url = Self.normalizedURL(urlField.stringValue) else { return NSSound.beep() }
                    if needsText {
                        let title = textField.stringValue.isEmpty ? url : textField.stringValue
                        self.insertLink(title, url: url, at: target)
                    } else {
                        self.applyLink(url, to: target)
                    }
                case .alertThirdButtonReturn:
                    self.removeLink(in: target)
                default:
                    break
                }
                self.view.window?.makeFirstResponder(self.textView)
            }
        }
    }

    /// What the user typed as a URL: `example.com` → `https://example.com`, `a@b.com` → `mailto:a@b.com`.
    static func normalizedURL(_ typed: String) -> String? {
        let s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return URL(string: s) != nil ? s : nil
        }
        let candidate = s.contains("@") && !s.contains("/") ? "mailto:" + s : "https://" + s
        return URL(string: candidate) != nil ? candidate : nil
    }

    private var hyperlinkStyleId: String? { document?.characterStyleId(named: "Hyperlink") }

    func applyLink(_ url: String, to range: NSRange) {
        guard let storage = textView.textStorage, range.length > 0 else { return }
        let style = hyperlinkStyleId
        let bridge = self.bridge
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        bridge.setLink(url, in: storage, range: range, hyperlinkStyleId: style)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Link"))
    }

    func removeLink(in range: NSRange) {
        guard let storage = textView.textStorage, range.length > 0 else { return }
        let style = document?.bridge.styles.styleId(named: "Hyperlink", type: "character")
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        bridge.removeLinks(in: storage, range: range, hyperlinkStyleId: style)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Remove Link"))
    }

    func insertLink(_ title: String, url: String, at range: NSRange) {
        guard let storage = textView.textStorage else { return }
        let style = hyperlinkStyleId
        let paragraph = AttributedStringBridge.paragraphRanges(in: storage, touching: range).first
        let styleId = paragraph.flatMap { AttributedStringBridge.paragraphFormatOf(storage, $0) }?.properties.styleId
        guard
            let link = bridge.linkText(
                title, url: url, typingAttributes: textView.typingAttributes, paragraphStyle: styleId,
                hyperlinkStyleId: style)
        else { return }
        textView.insertText(link, replacementRange: range)
        textView.undoManager?.setActionName(String(localized: "Link"))
    }

    // MARK: Following links

    /// ⌘-click opens a link (as in Word); a plain click just places the caret, so link text stays editable.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let url = link as? URL {
            NSWorkspace.shared.open(url)
        } else {
            textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        }
        return true
    }
}
