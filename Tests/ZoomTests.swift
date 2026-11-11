import AppKit
import XCTest

@testable import Libretilla

/// View zoom, as in Google Docs: ⌘+ / ⌘− / ⌘0 magnify the page; the text's font sizes don't change.
@MainActor
final class ZoomTests: XCTestCase {
    override func setUp() {
        // These start at 100%; the Fit tests below start with nothing saved (Fit, the default).
        UserDefaults.standard.set(1.0, forKey: DocumentWindowController.zoomKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.zoomKey)
    }

    func testZoomStepsThroughLevelsAndStopsAtTheEnds() throws {
        let doc = LibretillaDocument()
        makeWindow(for: doc)
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
        let doc = LibretillaDocument()
        makeWindow(for: doc)
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
        let doc = LibretillaDocument()
        makeWindow(for: doc)
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
        let doc = LibretillaDocument()
        makeWindow(for: doc)
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
        XCTAssertEqual(items(#selector(EditorViewController.zoomToFit(_:))).map(\.keyEquivalent), [""], "as in Docs")
        XCTAssertEqual(items(#selector(EditorViewController.increaseFontSize(_:))).map(\.keyEquivalent), [">"])
        XCTAssertEqual(items(#selector(EditorViewController.decreaseFontSize(_:))).map(\.keyEquivalent), ["<"])
    }

    // MARK: Fit

    /// A new window with nothing saved, laid out (Fit follows the window on the next turn of the run loop).
    private func fitWindow(width: CGFloat? = nil) throws -> (LibretillaDocument, EditorViewController, NSWindow) {
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.zoomKey)
        let doc = LibretillaDocument()
        makeWindow(for: doc)
        let editor = try XCTUnwrap(doc.editor)
        let window = try XCTUnwrap(editor.view.window)
        if let width { window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height)) }
        settle(window, editor)
        return (doc, editor, window)
    }

    /// Lets the window finish laying out (its controller adjusts the frame on the next turns of the run loop,
    /// and Fit follows), until the clip's width holds still.
    private func settle(_ window: NSWindow, _ editor: EditorViewController) {
        var last: CGFloat = -1
        for _ in 0..<20 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let width = editor.view.frame.width
            if width == last, !editor.fitsWidth || abs(editor.zoom - editor.fitWidthZoom) < 0.001 { break }
            last = width
        }
    }

    private func clipWidth(_ editor: EditorViewController) throws -> CGFloat {
        try XCTUnwrap(editor.textView.enclosingScrollView).contentView.frame.width
    }

    func testFitIsTheDefaultAndThePageTakesTheWindowsWidth() throws {
        let (doc, editor, _) = try fitWindow()
        defer { doc.close() }
        XCTAssertTrue(editor.fitsWidth)
        let canvas = try XCTUnwrap(editor.textView.superview as? PageCanvasView)
        XCTAssertFalse(canvas.isNarrow)
        XCTAssertEqual(canvas.pageRect.width * editor.zoom, try clipWidth(editor), accuracy: 1)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: DocumentWindowController.zoomKey), 0, "Fit is remembered as 0")
    }

    func testFitKeepsAJustOpenedDocumentAtItsTop() throws {
        // Fit zooms in after the window opens; the zoom keeps the middle line in place, which used to push the
        // title up out of sight (behind the toolbar). A view at the top of the page stays at the top.
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.zoomKey)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/generated/07-header-footer.docx")
        let doc = try LibretillaDocument(contentsOf: fixture, ofType: LibretillaDocument.docxType)
        makeWindow(for: doc)
        defer { doc.close() }
        let editor = try XCTUnwrap(doc.editor)
        let window = try XCTUnwrap(editor.view.window)
        settle(window, editor)
        XCTAssertTrue(editor.fitsWidth)
        XCTAssertGreaterThan(editor.zoom, 1.05, "the window is wider than the page")
        let clip = try XCTUnwrap(editor.textView.enclosingScrollView).contentView
        XCTAssertGreaterThan(clip.documentRect.height, clip.bounds.height, "the document scrolls")
        XCTAssertEqual(clip.bounds.minY, -clip.contentInsets.top, accuracy: 1, "the top of the page shows")
    }

    func testFitFollowsTheWindow() throws {
        let (doc, editor, window) = try fitWindow(width: 900)
        defer { doc.close() }
        let before = editor.zoom
        window.setContentSize(NSSize(width: 1100, height: window.contentLayoutRect.height))
        settle(window, editor)
        XCTAssertGreaterThan(editor.zoom, before)
        XCTAssertEqual(editor.pageSetup.pageSize.width * editor.zoom, try clipWidth(editor), accuracy: 1)
    }

    func testFitShrinksAPageWiderThanTheWindow() throws {
        let (doc, editor, _) = try fitWindow(width: 500)
        defer { doc.close() }
        let canvas = try XCTUnwrap(editor.textView.superview as? PageCanvasView)
        XCTAssertLessThan(editor.zoom, 1)
        XCTAssertFalse(canvas.isNarrow, "shrunk, the whole page shows")
        XCTAssertEqual(editor.pageSetup.pageSize.width * editor.zoom, try clipWidth(editor), accuracy: 1)
    }

    func testFitRewrapsOncePastTheLeastZoom() throws {
        let editor = EditorViewController()
        editor.loadView()
        let scroll = try XCTUnwrap(editor.view as? NSScrollView)
        let canvas = try XCTUnwrap(scroll.documentView as? PageCanvasView)
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        scroll.tile()
        editor.zoomToFit(nil)
        canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.zoom, 0.5, accuracy: 0.001, "50% is the least")
        XCTAssertTrue(canvas.isNarrow, "past the least zoom, the text rewraps")
    }

    func testFitStopsAtTheMostZoom() throws {
        let (doc, editor, window) = try fitWindow()
        defer { doc.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 3000, height: 800), display: false)
        settle(window, editor)
        if try clipWidth(editor) > 2 * editor.pageSetup.pageSize.width + 1 {
            XCTAssertEqual(editor.zoom, 2, accuracy: 0.001, "200% is the most")
        }
        XCTAssertLessThanOrEqual(editor.zoom, 2.0001)
    }

    func testFitLeavesRoomForPageEdges() throws {
        let (doc, editor, window) = try fitWindow(width: 900)
        defer { doc.close() }
        let controller = try XCTUnwrap(window.windowController as? DocumentWindowController)
        let edgesWere = UserDefaults.standard.object(forKey: DocumentWindowController.showsPageEdgesKey)
        defer { UserDefaults.standard.set(edgesWere, forKey: DocumentWindowController.showsPageEdgesKey) }
        if !editor.showsPageEdges { controller.togglePageEdges(nil) }
        settle(window, editor)
        let needed = editor.pageSetup.pageSize.width + 2 * PageCanvasView.edgePadding
        XCTAssertEqual(needed * editor.zoom, try clipWidth(editor), accuracy: 1)
    }

    func testZoomingLeavesFitAndZoomToFitReturns() throws {
        let (doc, editor, window) = try fitWindow(width: 900)
        defer { doc.close() }
        let fit = editor.zoom
        editor.zoomIn(nil)
        XCTAssertFalse(editor.fitsWidth)
        XCTAssertEqual(editor.zoom, EditorViewController.zoomLevels.first { $0 > fit + 0.001 } ?? 0, accuracy: 0.001)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: DocumentWindowController.zoomKey), Double(editor.zoom),
            accuracy: 0.001)
        let zoomed = editor.zoom
        window.setContentSize(NSSize(width: 1000, height: window.contentLayoutRect.height))
        settle(window, editor)
        XCTAssertEqual(editor.zoom, zoomed, accuracy: 0.001, "a set zoom doesn't follow the window")

        editor.zoomToFit(nil)
        XCTAssertTrue(editor.fitsWidth)
        XCTAssertEqual(editor.zoom, editor.fitWidthZoom, accuracy: 0.001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: DocumentWindowController.zoomKey), 0)
        editor.zoomToActualSize(nil)
        XCTAssertFalse(editor.fitsWidth)
        XCTAssertEqual(editor.zoom, 1, accuracy: 0.001)
    }
}
