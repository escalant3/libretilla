import AppKit
import CartillaDocx

/// The Insert menu (M3).
extension EditorViewController {
    /// Insert ▸ Page Break (⌘↩), as in Word: the text before the caret ends with a page break and the
    /// rest starts a new paragraph on the next page. One undo step.
    @objc func insertPageBreak(_ sender: Any?) {
        guard textView.isEditable else { return NSSound.beep() }
        let pageBreak = AttributedStringBridge.pageBreak(typingAttributes: textView.typingAttributes)
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        textView.insertText(pageBreak, replacementRange: textView.selectedRange())
        // A real Return, so lists and headings continue as they do when typing.
        textView.insertNewline(sender)
        undo?.setActionName(String(localized: "Page Break"))
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
    }
}
