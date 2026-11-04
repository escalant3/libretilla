import AppKit

final class DocumentWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("CartillaDocumentWindow")
        window.contentViewController = EditorViewController()
        window.center()
        self.init(window: window)
    }
}
