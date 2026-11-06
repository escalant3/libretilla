import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// A thin window works as a note-taking strip: the format bar overflows into a menu, the text rewraps to the
/// window, and the window can be as narrow as a phone.
@MainActor
final class NarrowWindowTests: XCTestCase {
    func testFormatBarShowsEverythingWhenWideAndOverflowsWhenNarrow() throws {
        let bar = FormatBarViewController()
        bar.loadViewIfNeeded()

        bar.fit(width: 1400)
        XCTAssertEqual(bar.hiddenGroups, [])

        // The default window (1040 points) shows the whole bar.
        bar.fit(width: 1040)
        XCTAssertEqual(bar.hiddenGroups, [])

        // A note-taking strip: only what fits stays, from the left; the rest is in the » menu.
        bar.fit(width: 320)
        XCTAssertFalse(bar.hiddenGroups.isEmpty)
        XCTAssertEqual(bar.hiddenGroups.last, .spacing)
        XCTAssertTrue(bar.hiddenGroups.contains(.character))
        let overflow = try XCTUnwrap(
            bar.view.firstDescendant {
                ($0 as? NSPopUpButton)?.accessibilityLabel() == String(localized: "More formatting")
            }
                as? NSPopUpButton)
        XCTAssertFalse(overflow.isHidden)
        let titles = overflow.itemArray.dropFirst().map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Font")), "\(titles)")
        XCTAssertTrue(titles.contains(String(localized: "Text")), "\(titles)")
        // Its copies of menu bar items carry no shortcuts (the menu bar answers those).
        let font = try XCTUnwrap(overflow.itemArray.first { $0.title == String(localized: "Font") }?.submenu)
        XCTAssertTrue(font.items.allSatisfy { $0.keyEquivalent.isEmpty })

        // Wide again: everything comes back and the » goes away.
        bar.fit(width: 1400)
        XCTAssertEqual(bar.hiddenGroups, [])
        XCTAssertTrue(overflow.isHidden)
    }

    func testTextRewrapsToANarrowWindowAndKeepsThePageWidthOtherwise() throws {
        let editor = EditorViewController()
        editor.loadView()
        let scroll = try XCTUnwrap(editor.view as? NSScrollView)
        let canvas = try XCTUnwrap(scroll.documentView as? PageCanvasView)

        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        scroll.tile()
        canvas.layoutSubtreeIfNeeded()
        XCTAssertTrue(canvas.isNarrow)
        XCTAssertEqual(editor.textView.frame.width, 360 - 2 * PageCanvasView.narrowInset, accuracy: 1)
        XCTAssertEqual(editor.textView.frame.minX, PageCanvasView.narrowInset, accuracy: 0.5)
        XCTAssertLessThanOrEqual(canvas.frame.width, 360.5, "no horizontal scrolling")

        scroll.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        scroll.tile()
        canvas.layoutSubtreeIfNeeded()
        XCTAssertFalse(canvas.isNarrow)
        XCTAssertEqual(editor.textView.frame.width, editor.pageSetup.textWidth, accuracy: 0.5)
    }

    func testDocumentWindowsCanBeAsNarrowAsANote() throws {
        let doc = LibretillaDocument()
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertEqual(window.contentMinSize.width, 320)
        XCTAssertLessThanOrEqual(window.frame.width, (NSScreen.main?.visibleFrame.width ?? .infinity) + 0.5)
    }
}

extension NSView {
    func firstDescendant(where match: (NSView) -> Bool) -> NSView? {
        for sub in subviews {
            if match(sub) { return sub }
            if let found = sub.firstDescendant(where: match) { return found }
        }
        return nil
    }
}
