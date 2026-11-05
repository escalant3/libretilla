import AppKit
import XCTest

@testable import Cartilla

/// View zoom, as in Google Docs: ⌘+ / ⌘− / ⌘0 magnify the page; the text's font sizes don't change.
@MainActor
final class ZoomTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.zoomKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.zoomKey)
    }

    func testZoomStepsThroughLevelsAndStopsAtTheEnds() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = try XCTUnwrap(doc.editor)
        XCTAssertEqual(editor.zoom, 1, accuracy: 0.001)

        editor.zoomIn(nil)
        XCTAssertEqual(editor.zoom, 1.25, accuracy: 0.001)
        editor.zoomIn(nil)
        editor.zoomIn(nil)
        editor.zoomIn(nil)
        XCTAssertEqual(editor.zoom, 2, accuracy: 0.001, "200% is the most")
        editor.zoomToActualSize(nil)
        XCTAssertEqual(editor.zoom, 1, accuracy: 0.001)
        editor.zoomOut(nil)
        XCTAssertEqual(editor.zoom, 0.9, accuracy: 0.001)
        for _ in 0..<5 { editor.zoomOut(nil) }
        XCTAssertEqual(editor.zoom, 0.5, accuracy: 0.001, "50% is the least")
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: DocumentWindowController.zoomKey), 0.5, accuracy: 0.001,
            "the zoom is remembered for the next window")
    }

    func testZoomDoesNotChangeTheText() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = try XCTUnwrap(doc.editor)
        editor.textView.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        let before = editor.textSnapshot()
        let undoable = doc.undoManager?.canUndo
        editor.zoomIn(nil)
        XCTAssertEqual(editor.textSnapshot(), before)
        XCTAssertEqual(doc.undoManager?.canUndo, undoable, "zooming isn't an edit")
    }

    func testPageStaysCentredWhenZoomedOut() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = try XCTUnwrap(doc.editor)
        let textView = try XCTUnwrap(editor.textView)
        let canvas = try XCTUnwrap(textView.superview as? PageCanvasView)
        editor.zoom = 0.5
        canvas.layoutSubtreeIfNeeded()
        let clip = try XCTUnwrap(canvas.superview)
        XCTAssertEqual(canvas.frame.width, clip.bounds.width, accuracy: 0.5, "the canvas fills the wider view")
        XCTAssertEqual(canvas.pageRect.midX, canvas.bounds.midX, accuracy: 1)
    }

    func testZoomedInTheViewShowsTheMiddleOfThePage() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = try XCTUnwrap(doc.editor)
        let canvas = try XCTUnwrap(editor.textView.superview as? PageCanvasView)
        let scrollView = try XCTUnwrap(editor.textView.enclosingScrollView)
        editor.zoom = 2
        let visible = scrollView.documentVisibleRect
        XCTAssertLessThan(visible.width, canvas.pageRect.width, "at 200% the page is wider than the window")
        XCTAssertEqual(visible.midX, canvas.pageRect.midX, accuracy: 1)
    }

    func testShortcuts() throws {
        let menu = MainMenu.make()
        func items(_ action: Selector) -> [NSMenuItem] {
            var found: [NSMenuItem] = []
            func walk(_ m: NSMenu) {
                for i in m.items {
                    if i.action == action { found.append(i) }
                    if let sub = i.submenu { walk(sub) }
                }
            }
            walk(menu)
            return found
        }
        XCTAssertEqual(
            Set(items(#selector(EditorViewController.zoomIn(_:))).map(\.keyEquivalent)), ["+", "="])
        XCTAssertEqual(items(#selector(EditorViewController.zoomOut(_:))).map(\.keyEquivalent), ["-"])
        XCTAssertEqual(items(#selector(EditorViewController.zoomToActualSize(_:))).map(\.keyEquivalent), ["0"])
        XCTAssertEqual(items(#selector(EditorViewController.increaseFontSize(_:))).map(\.keyEquivalent), [">"])
        XCTAssertEqual(items(#selector(EditorViewController.decreaseFontSize(_:))).map(\.keyEquivalent), ["<"])
    }
}
