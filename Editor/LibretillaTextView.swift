import AppKit
import LibretillaDocx

/// Keyboard behaviour that depends on the document's structure, as in Word and Google Docs:
/// Return on an empty list item ends the list, Return after a heading continues in its "next"
/// style, and Tab / Shift-Tab at the start of a list item change its level.
@MainActor
protocol LibretillaTextViewDelegate: AnyObject {
    /// Return was pressed; true if handled (the newline isn't inserted).
    func textViewHandleNewline(_ textView: LibretillaTextView) -> Bool
    /// A newline was just inserted.
    func textViewDidInsertNewline(_ textView: LibretillaTextView)
    /// Tab (`by` 1) or Shift-Tab (`by` -1); true if handled.
    func textView(_ textView: LibretillaTextView, changeListLevelBy delta: Int) -> Bool
    /// A double-click at character `index` (the insertion point nearest the click) on character `hit` (the
    /// one under the pointer, if any); true if handled (a table or picture opened in its editor).
    func textView(_ textView: LibretillaTextView, doubleClickedAt index: Int, on hit: Int?) -> Bool
}

final class LibretillaTextView: NSTextView {
    weak var structureDelegate: LibretillaTextViewDelegate?
    /// The document's headings, for VoiceOver's heading rotor.
    var headingsProvider: (() -> [OutlineHeading])?
    /// Called when the view's appearance changes (Dark Mode on or off).
    var onEffectiveAppearanceChange: (() -> Void)?

    /// The page's top margin: the space above the first line. The inset (TextKit's, the same above and below)
    /// is the average of the top and bottom margins, and the text starts this far down, so the space below the
    /// last line is the bottom margin. Nil uses the inset above too.
    var topMargin: CGFloat? {
        didSet { needsDisplay = true }
    }

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        if let topMargin { origin.y = topMargin }
        return origin
    }

    // MARK: Copy and paste within the document (backlog 23, 34)

    /// A private pasteboard type: a token naming the copy kept in `clipboard`.
    static let fragmentType = NSPasteboard.PasteboardType("app.libretilla.fragment")
    /// The last copy with its Word formatting, the token that names it, and the text it was copied from.
    private static var clipboard: (token: String, source: WeakStorage, text: NSAttributedString)?

    final class WeakStorage {
        weak var storage: NSTextStorage?
        init(_ storage: NSTextStorage?) { self.storage = storage }
    }

    /// Copies as AppKit does (RTF, plain text) and, for text without objects, keeps a copy with its Word formatting
    /// that a paste into the same document uses instead of the RTF, which only says how the text looks.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard super.writeSelection(to: pboard, types: types) else { return false }
        Self.clipboard = nil
        let range = selectedRange()
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length,
            let copy = AttributedStringBridge.internalCopy(of: storage.attributedSubstring(from: range))
        else { return true }
        let token = UUID().uuidString
        pboard.addTypes([Self.fragmentType], owner: nil)
        pboard.setString(token, forType: Self.fragmentType)
        Self.clipboard = (token, WeakStorage(storage), copy)
        return true
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let clip = Self.clipboard, pboard.string(forType: Self.fragmentType) == clip.token,
            clip.source.storage === textStorage,
            // A fresh copy for each paste: its links are new ones again.
            let text = AttributedStringBridge.internalCopy(of: clip.text)
        else { return super.readSelection(from: pboard) }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    // MARK: VoiceOver

    /// VoiceOver's rotor lists the headings (bootstrap §6), so a document can be navigated by them.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        super.accessibilityCustomRotors() + [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)]
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let hit = characterIndex(for: NSEvent.mouseLocation)
            let on = hit == NSNotFound ? nil : hit
            if structureDelegate?.textView(self, doubleClickedAt: index, on: on) == true { return }
        }
        super.mouseDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if structureDelegate?.textViewHandleNewline(self) == true { return }
        super.insertNewline(sender)
        structureDelegate?.textViewDidInsertNewline(self)
    }

    override func insertTab(_ sender: Any?) {
        if structureDelegate?.textView(self, changeListLevelBy: 1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if structureDelegate?.textView(self, changeListLevelBy: -1) == true { return }
        super.insertBacktab(sender)
    }

    // MARK: Ruler

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleRuler(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = isRulerVisible ? String(localized: "Hide Ruler") : String(localized: "Show Ruler")
        }
        return super.validateUserInterfaceItem(item)
    }

    /// The ruler shows indent and tab markers only. AppKit's accessory row (styles, alignment,
    /// spacing, lists) repeats the format bar, and its lists aren't Word lists.
    override func updateRuler() {
        super.updateRuler()
        guard let ruler = enclosingScrollView?.horizontalRulerView, ruler.clientView === self else { return }
        if ruler.accessoryView != nil {
            ruler.accessoryView = nil
            ruler.reservedThicknessForAccessoryView = 0
        }
        applyRulerUnits()
        alignRulerOrigin()
    }

    /// Settings ▸ Ruler units.
    func applyRulerUnits() {
        guard let ruler = enclosingScrollView?.horizontalRulerView, ruler.clientView === self else { return }
        let unit = Preferences.rulerUnit.measurementUnit
        if ruler.measurementUnits != unit { ruler.measurementUnits = unit }
    }

    /// Puts the ruler's zero at the left margin of the page (the ruler measures the canvas, and the
    /// page is centred in it).
    func alignRulerOrigin() {
        guard let ruler = enclosingScrollView?.horizontalRulerView, let canvas = superview else { return }
        let zero = canvas.convert(NSPoint(x: textContainerOrigin.x, y: 0), from: self).x
        if abs(ruler.originOffset - zero) > 0.5 { ruler.originOffset = zero }
    }
}

extension LibretillaTextView: @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        let headings = Self.headingSearch(
            headingsProvider?() ?? [], from: searchParameters.currentItem?.targetRange,
            direction: searchParameters.searchDirection, filter: searchParameters.filterString)
        guard let heading = headings else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = heading.range
        result.customLabel = heading.title
        return result
    }

    /// The next (or previous) heading after the rotor's current item whose title contains `filter`.
    static func headingSearch(
        _ headings: [OutlineHeading], from current: NSRange?, direction: NSAccessibilityCustomRotor.SearchDirection,
        filter: String
    ) -> OutlineHeading? {
        let matching = headings.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        guard let current else { return direction == .next ? matching.first : matching.last }
        return direction == .next
            ? matching.first { $0.range.location > current.location }
            : matching.last { $0.range.location < current.location }
    }
}
