import AppKit

/// Keyboard behaviour that depends on the document's structure, as in Word and Google Docs:
/// Return on an empty list item ends the list, Return after a heading continues in its "next"
/// style, and Tab / Shift-Tab at the start of a list item change its level.
@MainActor
protocol CartillaTextViewDelegate: AnyObject {
    /// Return was pressed; true if handled (the newline isn't inserted).
    func textViewHandleNewline(_ textView: CartillaTextView) -> Bool
    /// A newline was just inserted.
    func textViewDidInsertNewline(_ textView: CartillaTextView)
    /// Tab (`by` 1) or Shift-Tab (`by` -1); true if handled.
    func textView(_ textView: CartillaTextView, changeListLevelBy delta: Int) -> Bool
    /// A double-click at character `index`; true if handled (a table opened in the cell editor).
    func textView(_ textView: CartillaTextView, doubleClickedAt index: Int) -> Bool
}

final class CartillaTextView: NSTextView {
    weak var structureDelegate: CartillaTextViewDelegate?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if structureDelegate?.textView(self, doubleClickedAt: index) == true { return }
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
        alignRulerOrigin()
    }

    /// Puts the ruler's zero at the left margin of the page (the ruler measures the canvas, and the
    /// page is centred in it).
    func alignRulerOrigin() {
        guard let ruler = enclosingScrollView?.horizontalRulerView, let canvas = superview else { return }
        let zero = canvas.convert(NSPoint(x: textContainerOrigin.x, y: 0), from: self).x
        if abs(ruler.originOffset - zero) > 0.5 { ruler.originOffset = zero }
    }
}
