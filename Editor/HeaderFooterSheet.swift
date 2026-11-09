import AppKit
import LibretillaDocx
import SwiftUI

/// Format ▸ Header and Footer… (ADR 0007): the header and footer of the document's pages in two small text
/// views, laid out by the same bridge as the body, so their formatting shows and only what changes is rewritten.
/// "Different first page" gives page 1 its own pair. Page number and page count fields show as chips. Even-page
/// headers and footers are kept but not edited here. `onDone` gets the result, only if something changed.
@MainActor @Observable
final class HeaderFooterSheet {
    typealias Key = HeadersFooters.Key

    /// Whether page 1 has its own header and footer. Turning it off goes back to the other pages'.
    var differentFirstPage: Bool {
        didSet { if !differentFirstPage && slot == .first { choose(.default) } }
    }
    /// The pages being edited: `.default` (all pages, or all but the first) or `.first`.
    private(set) var slot: HeadersFooters.Slot = .default
    /// Why some of the document's headers and footers can't be edited here, if they can't.
    private(set) var note = ""

    @ObservationIgnored let textViews: [HeadersFooters.Kind: NSTextView]
    @ObservationIgnored var onDone: ((HeadersFooters, Bool) -> Void)?
    @ObservationIgnored private(set) var window: NSWindow?
    @ObservationIgnored private let original: HeadersFooters
    @ObservationIgnored private let originalDifferentFirstPage: Bool
    @ObservationIgnored private var result: HeadersFooters
    @ObservationIgnored private let bridge: AttributedStringBridge
    @ObservationIgnored private let styleIds: [HeadersFooters.Kind: String]
    /// The story each text view started from, for the slot shown.
    @ObservationIgnored private var shown: [HeadersFooters.Kind: HeadersFooters.Story] = [:]
    @ObservationIgnored private let delegate: StoryDelegate

    init(
        headersFooters: HeadersFooters, differentFirstPage: Bool, bridge: AttributedStringBridge,
        styleIds: [HeadersFooters.Kind: String]
    ) {
        original = headersFooters
        result = headersFooters
        originalDifferentFirstPage = differentFirstPage
        self.differentFirstPage = differentFirstPage
        self.bridge = bridge
        self.styleIds = styleIds
        let delegate = StoryDelegate(bridge: bridge)
        self.delegate = delegate
        var views: [HeadersFooters.Kind: NSTextView] = [:]
        for kind in HeadersFooters.Kind.allCases {
            views[kind] = Self.textView(kind, bridge: bridge, delegate: delegate)
        }
        textViews = views
        load(.default)
    }

    /// Shows the sheet on `parent`; `onEnd` runs once it has gone.
    func present(on parent: NSWindow, onEnd: @escaping @MainActor () -> Void) {
        window = Sheet.present(
            String(localized: "Header and Footer"), on: parent,
            content: HeaderFooterView(sheet: self, width: bridge.textWidth), onEnd: onEnd)
        window?.makeFirstResponder(textViews[.header])
    }

    private static func textView(
        _ kind: HeadersFooters.Kind, bridge: AttributedStringBridge, delegate: StoryDelegate
    ) -> NSTextView {
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
        tv.delegate = delegate
        tv.textStorage?.delegate = delegate
        tv.setAccessibilityLabel(kind == .header ? String(localized: "Header") : String(localized: "Footer"))
        return tv
    }

    // MARK: Slots

    /// Shows the header and footer of `slot`'s pages, keeping what was typed in the ones shown before.
    func choose(_ new: HeadersFooters.Slot) {
        guard new != slot else { return }
        commit()
        load(new)
    }

    private func load(_ slot: HeadersFooters.Slot) {
        self.slot = slot
        delegate.isLoading = true
        defer { delegate.isLoading = false }
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
        note = notes.joined(separator: " ")
        window?.makeFirstResponder(textViews[.header])
    }

    /// Takes the text views' contents into `result`.
    private func commit() {
        window?.makeFirstResponder(nil)
        for kind in HeadersFooters.Kind.allCases {
            let key = Key(kind, slot)
            guard let story = shown[kind], let storage = textViews[kind]?.textStorage,
                !result.unreadable.contains(key)
            else { continue }
            var edited = story
            edited.body = bridge.forStory(story).body(from: storage, base: story.body).body
            // A new story left empty makes no part.
            result.stories[key] = edited.partName == nil && edited.isEmpty ? nil : edited
        }
    }

    // MARK: Fields

    /// Inserts a page number or page count chip in the header or footer with the caret (the header if neither).
    func insert(_ field: PageField) {
        let focused = (window?.firstResponder as? NSTextView).flatMap { tv in textViews.values.first { $0 === tv } }
        guard let tv = focused ?? textViews[.header], tv.isEditable else { return NSSound.beep() }
        let range = tv.selectedRange()
        let chip = bridge.pageField(field, typingAttributes: tv.typingAttributes)
        guard tv.shouldChangeText(in: range, replacementString: chip.string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: chip)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + chip.length, length: 0))
        window?.makeFirstResponder(tv)
    }

    // MARK: Done

    func cancel() { Sheet.end(window) }

    func done() {
        commit()
        let changed = differentFirstPage != originalDifferentFirstPage || Self.differ(result, original)
        let out = result
        Sheet.end(window)
        if changed { onDone?(out, differentFirstPage) }
    }

    /// Whether any story was added, removed or changed.
    static func differ(_ a: HeadersFooters, _ b: HeadersFooters) -> Bool {
        guard Set(a.stories.keys) == Set(b.stories.keys) else { return true }
        return a.stories.contains { key, story in story.body.serialized() != b.stories[key]?.body.serialized() }
    }
}

/// Keeps the header and footer's Word formatting in step with their text, as the editor does for the body.
private final class StoryDelegate: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let bridge: AttributedStringBridge
    /// While a slot loads, storage edits are the bridge's own.
    var isLoading = false

    init(bridge: AttributedStringBridge) { self.bridge = bridge }

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
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard !isLoading, editedRange.location != NSNotFound else { return }
        bridge.reconcile(textStorage, range: editedRange)
    }
}

/// Pastes text without its formatting: the header's own formatting applies.
private final class PlainPasteTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

private struct HeaderFooterView: View {
    @Bindable var sheet: HeaderFooterSheet
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(String(localized: "Different first page"), isOn: $sheet.differentFirstPage)
                Spacer()
                if sheet.differentFirstPage {
                    Picker("", selection: Binding(get: { sheet.slot }, set: { sheet.choose($0) })) {
                        Text(String(localized: "First Page")).tag(HeadersFooters.Slot.first)
                        Text(String(localized: "Other Pages")).tag(HeadersFooters.Slot.default)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            story(String(localized: "Header"), .header)
            story(String(localized: "Footer"), .footer).padding(.top, 8)
            if !sheet.note.isEmpty {
                Text(sheet.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SheetButtons(
                cancel: sheet.cancel, confirmTitle: String(localized: "Done"),
                confirmShortcut: KeyboardShortcut(.return, modifiers: .command), confirm: sheet.done
            ) {
                Button(String(localized: "Insert Page Number")) { sheet.insert(.page) }
                Button(String(localized: "Insert Page Count")) { sheet.insert(.pageCount) }
            }
        }
        .padding(16)
        .frame(width: width + 32)
    }

    private func story(_ title: String, _ kind: HeadersFooters.Kind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold())
            if let tv = sheet.textViews[kind] { StoryEditor(textView: tv).frame(height: 80) }
        }
    }
}

/// One of the sheet's text views, in a bordered scroll view.
private struct StoryEditor: NSViewRepresentable {
    let textView: NSTextView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
