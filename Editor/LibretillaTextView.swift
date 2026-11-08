import AppKit

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
