import AppKit
import LibretillaDocx

/// Format ▸ Header and Footer… (ADR 0007): the header and footer of the document's pages in two small text
/// views, laid out by the same bridge as the body, so their formatting shows and only what changes is rewritten.
/// "Different first page" gives page 1 its own pair. Page number and page count fields show as chips. Even-page
/// headers and footers are kept but not edited here. `onDone` gets the result, only if something changed.
final class HeaderFooterController: NSWindowController, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    typealias Key = HeadersFooters.Key

    private let original: HeadersFooters
    private let originalDifferentFirstPage: Bool
    private var result: HeadersFooters
    private let bridge: AttributedStringBridge
    private let styleIds: [HeadersFooters.Kind: String]
    /// The pages being edited: `.default` (all pages, or all but the first) or `.first`.
    private(set) var slot: HeadersFooters.Slot = .default
    /// The story each text view started from, for the slot shown.
    private var shown: [HeadersFooters.Kind: HeadersFooters.Story] = [:]
    private(set) var textViews: [HeadersFooters.Kind: NSTextView] = [:]
    private(set) var differentFirstPage: NSButton!
    private(set) var pages: NSSegmentedControl!
    private let note = NSTextField(wrappingLabelWithString: "")
    /// While a slot loads, storage edits are the bridge's own.
    private var isLoading = false
    var onDone: ((HeadersFooters, Bool) -> Void)?

    init(
        headersFooters: HeadersFooters, differentFirstPage: Bool, bridge: AttributedStringBridge,
        styleIds: [HeadersFooters.Kind: String]
    ) {
        original = headersFooters
        result = headersFooters
        originalDifferentFirstPage = differentFirstPage
        self.bridge = bridge
        self.styleIds = styleIds
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: bridge.textWidth + 48, height: 360), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.title = String(localized: "Header and Footer")
        super.init(window: window)
        buildWindow(differentFirstPage: differentFirstPage)
        load(.default)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        return b
    }

    private func storyView(_ kind: HeadersFooters.Kind) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = PlainPasteTextView(usingTextLayoutManager: true)
        // The page is white, as in the editor's default; text colours are the document's.
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.drawsBackground = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 0
        // As wide as the page's text column, so tab stops and alignment look as printed.
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: bridge.textWidth, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.delegate = self
        tv.textStorage?.delegate = self
        tv.setAccessibilityLabel(
            kind == .header ? String(localized: "Header") : String(localized: "Footer"))
        scroll.documentView = tv
        textViews[kind] = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        return scroll
    }

    private func buildWindow(differentFirstPage on: Bool) {
        guard let content = window?.contentView else { return }
        differentFirstPage = NSButton(
            checkboxWithTitle: String(localized: "Different first page"), target: self,
            action: #selector(toggleDifferentFirstPage(_:)))
        differentFirstPage.state = on ? .on : .off
        pages = NSSegmentedControl(
            labels: [String(localized: "First Page"), String(localized: "Other Pages")], trackingMode: .selectOne,
            target: self, action: #selector(choosePages(_:)))
        pages.selectedSegment = 1
        pages.isHidden = !on
        let top = NSStackView(views: [differentFirstPage, NSView(), pages])
        top.orientation = .horizontal

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            return l
        }
        let header = storyView(.header)
        let footer = storyView(.footer)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let pageNumber = button(String(localized: "Insert Page Number"), #selector(insertPageNumber(_:)))
        let pageCount = button(String(localized: "Insert Page Count"), #selector(insertPageCount(_:)))
        let cancel = button(String(localized: "Cancel"), #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = button(String(localized: "Done"), #selector(done(_:)))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [pageNumber, pageCount, spacer, cancel, done])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            top, label(String(localized: "Header")), header, label(String(localized: "Footer")), footer, note, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        for view in [top, header, footer, note, buttons] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32))
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: Slots

    /// Shows the header and footer of `slot`'s pages.
    private func load(_ slot: HeadersFooters.Slot) {
        self.slot = slot
        isLoading = true
        defer { isLoading = false }
        for kind in HeadersFooters.Kind.allCases {
            let key = Key(kind, slot)
            let story = result.stories[key] ?? HeadersFooters.newStory(kind, styleId: styleIds[kind])
            shown[kind] = story
            guard let tv = textViews[kind] else { continue }
            tv.textStorage?.setAttributedString(bridge.forStory(story).attributedString(for: story.body))
            tv.isEditable = !result.unreadable.contains(key)
            tv.undoManager?.removeAllActions()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        var notes: [String] = []
        if HeadersFooters.Kind.allCases.contains(where: { result.unreadable.contains(Key($0, slot)) }) {
            notes.append(String(localized: "A header or footer that Libretilla can't read is kept as it is."))
        }
        if result.evenAndOddPages {
            notes.append(
                String(
                    localized: "Even pages have their own header and footer, which are kept but can't be edited here."))
        }
        note.stringValue = notes.joined(separator: " ")
        note.isHidden = notes.isEmpty
        window?.makeFirstResponder(textViews[.header])
    }

    /// Takes the text views' contents into `result`.
    private func commit() {
        window?.makeFirstResponder(nil)
        for kind in HeadersFooters.Kind.allCases {
            let key = Key(kind, slot)
            guard let story = shown[kind], let tv = textViews[kind], let storage = tv.textStorage,
                !result.unreadable.contains(key)
            else { continue }
            var edited = story
            edited.body = bridge.forStory(story).body(from: storage, base: story.body).body
            // A new story left empty makes no part.
            result.stories[key] = edited.partName == nil && edited.isEmpty ? nil : edited
        }
    }

    @objc func toggleDifferentFirstPage(_ sender: Any?) {
        let on = differentFirstPage.state == .on
        pages.isHidden = !on
        if !on && slot == .first {
            commit()
            pages.selectedSegment = 1
            load(.default)
        }
    }

    @objc func choosePages(_ sender: Any?) {
        let new: HeadersFooters.Slot = pages.selectedSegment == 0 ? .first : .default
        guard new != slot else { return }
        commit()
        load(new)
    }

    // MARK: Fields

    @objc func insertPageNumber(_ sender: Any?) { insert(.page) }
    @objc func insertPageCount(_ sender: Any?) { insert(.pageCount) }

    /// The header or footer text view with the caret (the header if neither has it).
    private var focusedTextView: NSTextView? {
        if let tv = window?.firstResponder as? NSTextView, textViews.values.contains(tv) { return tv }
        return textViews[.header]
    }

    private func insert(_ field: PageField) {
        guard let tv = focusedTextView, tv.isEditable else { return NSSound.beep() }
        let range = tv.selectedRange()
        let chip = bridge.pageField(field, typingAttributes: tv.typingAttributes)
        guard tv.shouldChangeText(in: range, replacementString: chip.string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: chip)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + chip.length, length: 0))
        window?.makeFirstResponder(tv)
    }

    // MARK: Text views

    func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = newTypingAttributes
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        return attrs
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isLoading, editedRange.location != NSNotFound else { return }
        bridge.reconcile(textStorage, range: editedRange)
    }

    // MARK: Done

    @objc func cancel(_ sender: Any?) { end() }

    @objc func done(_ sender: Any?) {
        commit()
        let on = differentFirstPage.state == .on
        let changed = on != originalDifferentFirstPage || Self.differ(result, original)
        let out = result
        end()
        if changed { onDone?(out, on) }
    }

    /// Whether any story was added, removed or changed.
    static func differ(_ a: HeadersFooters, _ b: HeadersFooters) -> Bool {
        guard Set(a.stories.keys) == Set(b.stories.keys) else { return true }
        return a.stories.contains { key, story in story.body.serialized() != b.stories[key]?.body.serialized() }
    }

    private func end() {
        guard let window, let parent = window.sheetParent else {
            window?.close()
            return
        }
        parent.endSheet(window)
    }
}

/// Pastes text without its formatting: the header's own formatting applies.
private final class PlainPasteTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}
