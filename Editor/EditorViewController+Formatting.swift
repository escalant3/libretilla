import AppKit
import LibretillaDocx

/// Formatting commands (M2), reached through the responder chain from the Format menu and the
/// format bar. Each one is a single undoable edit that changes the Word formatting (`RunFormat`,
/// `ParagraphFormat`) and redraws the text from it.
extension EditorViewController: NSMenuItemValidation, LibretillaTextViewDelegate {
    // MARK: - Edit plumbing

    var currentFormat: SelectionFormat {
        bridge.selectionFormat(
            textView.textStorage ?? NSTextStorage(), range: textView.selectedRange(),
            typingAttributes: textView.typingAttributes)
    }

    private var selectedRanges: [NSRange] { textView.selectedRanges.map(\.rangeValue) }

    /// Character formatting: on the selection, or on the typing attributes for a caret.
    func editRuns(_ change: RunChange, actionName: String) {
        guard textView.isEditable, let storage = textView.textStorage else { return NSSound.beep() }
        let bridge = self.bridge
        let ranges = selectedRanges.filter { $0.length > 0 }
        if ranges.isEmpty {
            let caret = textView.selectedRange().location
            let paragraph = AttributedStringBridge.paragraphRanges(
                in: storage, touching: NSRange(location: caret, length: 0)
            ).first
            let styleId = paragraph.flatMap { AttributedStringBridge.paragraphFormatOf(storage, $0) }?.properties
                .styleId
            textView.typingAttributes = bridge.typingAttributes(
                textView.typingAttributes, applying: change, paragraphStyle: styleId)
            scheduleSelectionUpdate()
            return
        }
        let values = ranges.map { NSValue(range: $0) }
        guard textView.shouldChangeText(inRanges: values, replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges { bridge.apply(change, to: storage, range: r) }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
    }

    /// Paragraph formatting on every paragraph the selection touches.
    func editParagraphs(_ change: ParagraphChange, actionName: String, bridge override: AttributedStringBridge? = nil) {
        guard textView.isEditable, let storage = textView.textStorage, storage.length > 0 else { return NSSound.beep() }
        let bridge = override ?? self.bridge
        let paragraphs = selectedRanges.flatMap { AttributedStringBridge.paragraphRanges(in: storage, touching: $0) }
        guard let first = paragraphs.first else { return }
        let affected = paragraphs.reduce(first) { NSUnionRange($0, $1) }
        guard textView.shouldChangeText(in: affected, replacementString: nil) else { return }
        storage.beginEditing()
        bridge.apply(change, to: storage, range: affected)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        renumberNow(bridge)
        refreshTypingAttributes()
    }

    /// List markers are display only: updated outside the undoable edit.
    func renumberNow(_ bridge: AttributedStringBridge) {
        guard let storage = textView.textStorage else { return }
        withoutReconciling {
            storage.beginEditing()
            bridge.renumber(storage)
            storage.endEditing()
        }
    }

    /// After a paragraph change at a caret, typed text should look like the paragraph now does.
    private func refreshTypingAttributes() {
        guard let storage = textView.textStorage, textView.selectedRange().length == 0, storage.length > 0 else {
            return
        }
        let caret = min(textView.selectedRange().location, storage.length - 1)
        var attrs = storage.attributes(
            at: caret > 0 && caret == storage.length ? caret - 1 : caret, effectiveRange: nil)
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        if (storage.string as NSString).character(at: caret) == 0x0A, caret > 0,
            (storage.string as NSString).character(at: caret - 1) != 0x0A
        {
            // Caret at the end of a non-empty paragraph: keep the run before it.
            var before = storage.attributes(at: caret - 1, effectiveRange: nil)
            for key in NSAttributedString.Key.libretillaNonInheritable { before[key] = nil }
            before[.paragraphStyle] = attrs[.paragraphStyle]
            before[.libretillaParagraphFormat] = attrs[.libretillaParagraphFormat]
            attrs = before
        }
        textView.typingAttributes = attrs
    }

    // MARK: - Character commands

    @objc func toggleBold(_ sender: Any?) {
        editRuns(.bold(!currentFormat.bold), actionName: String(localized: "Bold"))
    }

    @objc func toggleItalic(_ sender: Any?) {
        editRuns(.italic(!currentFormat.italic), actionName: String(localized: "Italic"))
    }

    @objc func toggleUnderline(_ sender: Any?) {
        editRuns(.underline(!currentFormat.underline), actionName: String(localized: "Underline"))
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        editRuns(.strike(!currentFormat.strike), actionName: String(localized: "Strikethrough"))
    }

    @objc func toggleSuperscript(_ sender: Any?) {
        let on = currentScript == "superscript"
        editRuns(.verticalAlignment(on ? nil : "superscript"), actionName: String(localized: "Superscript"))
    }

    @objc func toggleSubscript(_ sender: Any?) {
        let on = currentScript == "subscript"
        editRuns(.verticalAlignment(on ? nil : "subscript"), actionName: String(localized: "Subscript"))
    }

    private var currentScript: String? {
        let attrs: [NSAttributedString.Key: Any]
        if textView.selectedRange().length > 0, let storage = textView.textStorage {
            attrs = storage.attributes(at: textView.selectedRange().location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        let v = (attrs[.superscript] as? Int) ?? 0
        return v > 0 ? "superscript" : v < 0 ? "subscript" : nil
    }

    static let standardSizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]

    @objc func increaseFontSize(_ sender: Any?) {
        let size = currentFormat.fontSize ?? 11
        let next = Self.standardSizes.first { $0 > size } ?? size + 12
        editRuns(.size(next), actionName: String(localized: "Font Size"))
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        let size = currentFormat.fontSize ?? 11
        let next = Self.standardSizes.last { $0 < size } ?? max(1, size - 1)
        editRuns(.size(next), actionName: String(localized: "Font Size"))
    }

    /// The format bar's font menu.
    func applyFontFamily(_ family: String) {
        guard !family.isEmpty else { return }
        editRuns(.font(family), actionName: String(localized: "Font"))
        view.window?.makeFirstResponder(textView)
    }

    /// The format bar's size box: what was typed, in points ("10,5" as well as "10.5").
    func applyFontSize(_ typed: String) {
        guard let value = Double(typed.replacingOccurrences(of: ",", with: ".")), value >= 1, value <= 1638 else {
            return NSSound.beep()
        }
        // Word stores half points.
        editRuns(.size((value * 2).rounded() / 2), actionName: String(localized: "Font Size"))
        view.window?.makeFirstResponder(textView)
    }

    /// The format bar's colour well.
    func applyTextColor(_ color: NSColor) {
        editRuns(.color(AttributedStringBridge.hex(color)), actionName: String(localized: "Text Color"))
    }

    @objc func applyAutomaticTextColor(_ sender: Any?) {
        editRuns(.color(nil), actionName: String(localized: "Text Color"))
    }

    @objc func applyHighlight(_ sender: Any?) {
        applyHighlight(named: (sender as? NSMenuItem)?.representedObject as? String)
    }

    /// A Word highlight colour by name (`yellow`…), or none.
    func applyHighlight(named name: String?) {
        editRuns(.highlight(name), actionName: String(localized: "Highlight"))
    }

    @objc func clearFormatting(_ sender: Any?) {
        guard textView.isEditable, let storage = textView.textStorage, storage.length > 0 else { return NSSound.beep() }
        let ranges = selectedRanges.filter { $0.length > 0 }
        let paragraphs = selectedRanges.flatMap { AttributedStringBridge.paragraphRanges(in: storage, touching: $0) }
        guard let first = paragraphs.first else { return }
        let affected = paragraphs.reduce(first) { NSUnionRange($0, $1) }
        guard textView.shouldChangeText(in: affected, replacementString: nil) else { return }
        let bridge = self.bridge
        storage.beginEditing()
        for r in ranges { bridge.apply(RunChange.clear, to: storage, range: r) }
        bridge.apply(ParagraphChange.clear, to: storage, range: affected)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Clear Formatting"))
        if ranges.isEmpty {
            textView.typingAttributes = bridge.typingAttributes(
                textView.typingAttributes, applying: .clear,
                paragraphStyle: AttributedStringBridge.paragraphFormatOf(storage, first)?.properties.styleId)
        }
    }

    // MARK: - Paragraph commands

    /// Tags: 0 left, 1 centre, 2 right, 3 justify (also the format bar's segment order).
    static let alignments = ["left", "center", "right", "both"]

    @objc func applyAlignment(_ sender: Any?) { applyAlignment(at: (sender as? NSMenuItem)?.tag ?? 0) }

    /// An alignment by its index in `alignments`.
    func applyAlignment(at index: Int) {
        guard Self.alignments.indices.contains(index) else { return }
        editParagraphs(.alignment(Self.alignments[index]), actionName: String(localized: "Alignment"))
    }

    /// Line spacing values offered (the Format menu's and the format bar's), as multiples of single spacing.
    static let lineSpacings: [(title: String, value: Double)] = [("1", 1), ("1.15", 1.15), ("1.5", 1.5), ("2", 2)]

    @objc func applyLineSpacing(_ sender: Any?) {
        guard let multiple = (sender as? NSMenuItem)?.representedObject as? Double else { return }
        applyLineSpacing(multiple: multiple)
    }

    func applyLineSpacing(multiple: Double) {
        editParagraphs(.lineSpacing(multiple), actionName: String(localized: "Line Spacing"))
    }

    @objc func toggleSpaceBefore(_ sender: Any?) {
        let add = currentFormat.spaceBefore < 1
        editParagraphs(.spaceBefore(add ? 12 : 0), actionName: String(localized: "Paragraph Spacing"))
    }

    @objc func toggleSpaceAfter(_ sender: Any?) {
        let add = currentFormat.spaceAfter < 1
        editParagraphs(.spaceAfter(add ? 12 : 0), actionName: String(localized: "Paragraph Spacing"))
    }

    @objc func increaseIndent(_ sender: Any?) {
        if currentFormat.isListItem {
            editParagraphs(.listLevel(by: 1), actionName: String(localized: "Indent"))
        } else {
            editParagraphs(.indent(by: 36), actionName: String(localized: "Indent"))
        }
    }

    @objc func decreaseIndent(_ sender: Any?) {
        if currentFormat.isListItem {
            editParagraphs(.listLevel(by: -1), actionName: String(localized: "Indent"))
        } else {
            editParagraphs(.indent(by: -36), actionName: String(localized: "Indent"))
        }
    }

    @objc func toggleBulletedList(_ sender: Any?) { toggleList(.bullet) }

    @objc func toggleNumberedList(_ sender: Any?) { toggleList(.numbered) }

    func toggleList(_ kind: Numbering.ListKind) {
        guard textView.isEditable, let storage = textView.textStorage, let document else { return NSSound.beep() }
        let name = kind == .bullet ? String(localized: "Bulleted List") : String(localized: "Numbered List")
        if currentFormat.list == kind {
            editParagraphs(.list(numId: nil, level: nil), actionName: name)
            return
        }
        // Continue the list just above, as Word and Google Docs do; otherwise start a new one.
        let first = AttributedStringBridge.paragraphRanges(in: storage, touching: textView.selectedRange()).first
        var numId: Int?
        if let first, first.location > 0 {
            let above = (storage.string as NSString).paragraphRange(
                for: NSRange(location: first.location - 1, length: 0))
            if let format = AttributedStringBridge.paragraphFormatOf(storage, above) {
                let effective = bridge.effectiveParagraph(format.properties)
                if effective.hasNumbering, bridge.numbering.isBullet(numId: effective.numId!) == (kind == .bullet) {
                    numId = effective.numId
                }
            }
        }
        if numId == nil { numId = document.addList(kind) }
        guard let numId else { return NSSound.beep() }
        editParagraphs(.list(numId: numId, level: nil), actionName: name, bridge: document.bridge)
    }

    // MARK: - Styles

    /// Format ▸ Style items carry a `StyleChoice` key as their represented object.
    @objc func applyParagraphStyle(_ sender: Any?) {
        if let key = (sender as? NSMenuItem)?.representedObject as? String { applyParagraphStyle(key: key) }
    }

    /// The style a `StyleChoice` key stands for (the format bar's style menu, Format ▸ Style).
    func applyParagraphStyle(key: String) {
        guard let document, let choice = StyleChoice(key: key) else { return }
        let id: String?
        switch choice {
        case .builtIn(let name): id = document.paragraphStyleId(named: name)
        case .document(let styleId): id = styleId
        }
        guard let id else { return NSSound.beep() }
        let normal = document.bridge.styles.defaultParagraphStyleId
        editParagraphs(
            .style(id == normal ? nil : id), actionName: String(localized: "Paragraph Style"), bridge: document.bridge)
        view.window?.makeFirstResponder(textView)
    }

    /// Word's "Update Style to Match Selection": the selection's direct formatting moves into its
    /// paragraph style (so every paragraph in that style changes), and leaves the selection.
    @objc func updateStyleToMatchSelection(_ sender: Any?) {
        guard textView.isEditable, let storage = textView.textStorage, storage.length > 0, let document else {
            return NSSound.beep()
        }
        let bridge = self.bridge
        let paragraphs = AttributedStringBridge.paragraphRanges(in: storage, touching: textView.selectedRange())
        guard let first = paragraphs.first else { return }
        let paragraphFormat = AttributedStringBridge.paragraphFormatOf(storage, first)
        let styleId = paragraphFormat?.properties.styleId ?? bridge.styles.defaultParagraphStyleId
        guard let styleId else { return NSSound.beep() }
        let p = paragraphFormat?.properties ?? ParagraphProperties()
        var paragraphFields: Set<ParagraphProperties.Field> = []
        if p.alignment != nil { paragraphFields.insert(.alignment) }
        if p.spaceBefore != nil { paragraphFields.insert(.spaceBefore) }
        if p.spaceAfter != nil { paragraphFields.insert(.spaceAfter) }
        if p.line != nil { paragraphFields.insert(.lineSpacing) }
        if p.indentLeft != nil || p.firstLine != nil || p.indentRight != nil { paragraphFields.insert(.indentation) }
        // The run at the start of the selection (or before the caret).
        let at =
            textView.selectedRange().length > 0
            ? textView.selectedRange().location : max(0, textView.selectedRange().location - 1)
        let run =
            (storage.attribute(.libretillaRun, at: min(at, storage.length - 1), effectiveRange: nil) as? RunFormat)?
            .properties ?? RunProperties()
        var runFields: Set<RunProperties.Field> = []
        if run.bold != nil { runFields.insert(.bold) }
        if run.italic != nil { runFields.insert(.italic) }
        if run.underline != nil { runFields.insert(.underline) }
        if run.strike != nil { runFields.insert(.strike) }
        if run.size != nil { runFields.insert(.size) }
        if run.font != nil || run.themeFont != nil { runFields.insert(.font) }
        if run.color != nil { runFields.insert(.color) }
        if run.highlight != nil { runFields.insert(.highlight) }
        guard !paragraphFields.isEmpty || !runFields.isEmpty else { return NSSound.beep() }

        var styles = bridge.styles
        styles.updateStyle(styleId, paragraph: p, paragraphFields: paragraphFields, run: run, runFields: runFields)
        let name = String(localized: "Update Style")
        document.setStyles(styles, actionName: name)

        // Re-applying the now-inherited values removes them as direct formatting.
        let newBridge = document.bridge
        let affected = paragraphs.reduce(first) { NSUnionRange($0, $1) }
        guard textView.shouldChangeText(in: affected, replacementString: nil) else { return }
        storage.beginEditing()
        var changes: [RunChange] = []
        if let v = run.bold { changes.append(.bold(v)) }
        if let v = run.italic { changes.append(.italic(v)) }
        if let v = run.underline { changes.append(.underline(v)) }
        if let v = run.strike { changes.append(.strike(v)) }
        if let v = run.size { changes.append(.size(v)) }
        if let v = run.font ?? newBridge.styles.fontFamily(for: run) { changes.append(.font(v)) }
        if let v = run.color { changes.append(.color(v == "auto" ? nil : v)) }
        if let v = run.highlight { changes.append(.highlight(v == "none" ? nil : v)) }
        for paragraph in paragraphs
        where AttributedStringBridge.paragraphFormatOf(storage, paragraph)?.properties.styleId ?? styleId == styleId {
            for c in changes { newBridge.apply(c, to: storage, range: paragraph) }
            newBridge.apply(ParagraphChange.clear, to: storage, range: paragraph)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(name)
    }

    // MARK: - Keyboard (LibretillaTextViewDelegate)

    private func caretParagraph() -> (range: NSRange, isEmpty: Bool)? {
        guard let storage = textView.textStorage, textView.selectedRange().length == 0 else { return nil }
        let ns = storage.string as NSString
        let r = ns.paragraphRange(for: NSRange(location: min(textView.selectedRange().location, ns.length), length: 0))
        let content = r.length > 0 && ns.character(at: NSMaxRange(r) - 1) == 0x0A ? r.length - 1 : r.length
        return (r, content == 0)
    }

    func textViewHandleNewline(_ textView: LibretillaTextView) -> Bool {
        // Return on an empty list item ends the list.
        guard let (_, isEmpty) = caretParagraph(), isEmpty, currentFormat.isListItem else { return false }
        editParagraphs(.list(numId: nil, level: nil), actionName: String(localized: "Typing"))
        return true
    }

    func textViewDidInsertNewline(_ textView: LibretillaTextView) {
        // An empty range is past the last paragraph mark: not a paragraph (styling it would hit the one before).
        guard let storage = textView.textStorage, let (range, isEmpty) = caretParagraph(), isEmpty, range.location > 0,
            range.length > 0
        else { return }
        let previous = (storage.string as NSString).paragraphRange(
            for: NSRange(location: range.location - 1, length: 0))
        let bridge = self.bridge
        let previousStyle = AttributedStringBridge.paragraphFormatOf(storage, previous)?.properties.styleId
        guard let id = previousStyle, let next = bridge.styles.styles[id]?.next, next != id else { return }
        // After a heading, continue in its "next" style (usually Normal), as Word does.
        let normal = bridge.styles.defaultParagraphStyleId
        let nextId = next == normal ? nil : next
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        bridge.apply(ParagraphChange.style(nextId), to: storage, range: range)
        storage.endEditing()
        textView.didChangeText()
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        attrs[.libretillaRun] = nil
        textView.typingAttributes = attrs
    }

    func textView(_ textView: LibretillaTextView, doubleClickedAt index: Int, on hit: Int?) -> Bool {
        if let hit, isPicture(at: hit) {
            openPictureFormatter(at: hit)
            return true
        }
        guard let found = table(at: index) else { return false }
        openTableEditor(found)
        return true
    }

    func textView(_ textView: LibretillaTextView, changeListLevelBy delta: Int) -> Bool {
        guard textView.isEditable, currentFormat.isListItem, let storage = textView.textStorage else { return false }
        let sel = textView.selectedRange()
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0))
        // Tab inside the text of a list item types a tab; at its start (or over several items) it nests.
        guard sel.length > 0 || sel.location == paragraph.location else { return false }
        editParagraphs(.listLevel(by: delta), actionName: String(localized: "Indent"))
        return true
    }

    // MARK: - Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        if action == #selector(editTable(_:)) { return tableAtSelection != nil && textView.isEditable }
        if action == #selector(formatPicture(_:)) { return pictureIndex(for: item) != nil && textView.isEditable }
        if action == #selector(editHeaderAndFooter(_:)) || action == #selector(editMargins(_:)) {
            return textView.isEditable && document != nil
        }
        switch action {
        case #selector(zoomIn(_:)): return zoom < Self.zoomLevels.last! - 0.001
        case #selector(zoomOut(_:)): return zoom > Self.zoomLevels.first! + 0.001
        case #selector(zoomToActualSize(_:)): return fitsWidth || abs(zoom - 1) > 0.001
        case #selector(zoomToFit(_:)):
            item.state = fitsWidth ? .on : .off
            return true
        default: break
        }
        let format = currentFormat
        switch action {
        case #selector(toggleBold(_:)): item.state = format.bold ? .on : .off
        case #selector(toggleItalic(_:)): item.state = format.italic ? .on : .off
        case #selector(toggleUnderline(_:)): item.state = format.underline ? .on : .off
        case #selector(toggleStrikethrough(_:)): item.state = format.strike ? .on : .off
        case #selector(toggleSuperscript(_:)): item.state = currentScript == "superscript" ? .on : .off
        case #selector(toggleSubscript(_:)): item.state = currentScript == "subscript" ? .on : .off
        case #selector(applyAlignment(_:)):
            item.state = format.alignment == Self.alignments[safe: item.tag] ? .on : .off
        case #selector(toggleBulletedList(_:)): item.state = format.list == .bullet ? .on : .off
        case #selector(toggleNumberedList(_:)): item.state = format.list == .numbered ? .on : .off
        case #selector(applyLineSpacing(_:)):
            let v = item.representedObject as? Double
            item.state = v != nil && format.lineSpacing.map { abs($0 - v!) < 0.01 } == true ? .on : .off
        case #selector(toggleSpaceBefore(_:)):
            item.title =
                format.spaceBefore < 1
                ? String(localized: "Add Space Before Paragraph") : String(localized: "Remove Space Before Paragraph")
        case #selector(toggleSpaceAfter(_:)):
            item.title =
                format.spaceAfter < 1
                ? String(localized: "Add Space After Paragraph") : String(localized: "Remove Space After Paragraph")
        case #selector(applyParagraphStyle(_:)):
            if let key = item.representedObject as? String, let choice = StyleChoice(key: key) {
                item.state = choice.matches(format.styleId, in: bridge.styles) ? .on : .off
            }
        default: break
        }
        return textView.isEditable
    }
}

/// What a style popup item stands for: one of Libretilla's standard styles (by Word's built-in
/// name, created on first use if the document lacks it) or a style the document defines.
enum StyleChoice: Equatable {
    case builtIn(String)
    case document(String)

    init?(key: String) {
        if key.hasPrefix("builtin:") {
            self = .builtIn(String(key.dropFirst(8)))
        } else if key.hasPrefix("id:") {
            self = .document(String(key.dropFirst(3)))
        } else {
            return nil
        }
    }

    var key: String {
        switch self {
        case .builtIn(let n): "builtin:" + n
        case .document(let id): "id:" + id
        }
    }

    func matches(_ styleId: String?, in styles: StyleSheet) -> Bool {
        let id = styleId ?? styles.defaultParagraphStyleId
        switch self {
        case .builtIn(let name): return id != nil && styles.styleId(named: name) == id
        case .document(let docId): return docId == id
        }
    }

    /// The standard styles, in popup order, with their display titles (bootstrap §4).
    static let standard: [(name: String, title: String)] = [
        ("Normal", String(localized: "Normal")),
        ("Title", String(localized: "Title")),
        ("Subtitle", String(localized: "Subtitle")),
        ("heading 1", String(localized: "Heading 1")),
        ("heading 2", String(localized: "Heading 2")),
        ("heading 3", String(localized: "Heading 3")),
        ("heading 4", String(localized: "Heading 4")),
        ("heading 5", String(localized: "Heading 5")),
        ("heading 6", String(localized: "Heading 6")),
        ("Quote", String(localized: "Quote")),
        ("Source Code", String(localized: "Code")),
    ]
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
