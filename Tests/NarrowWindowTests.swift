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
        let titles = FormatBarViewController.overflowMenus(for: bar.hiddenGroups).map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Font")), "\(titles)")
        XCTAssertTrue(titles.contains(String(localized: "Text")), "\(titles)")
        // Its copies of menu bar items carry no shortcuts (the menu bar answers those).
        let font = try XCTUnwrap(
            FormatBarViewController.overflowMenus(for: bar.hiddenGroups).first { $0.title == String(localized: "Font") }
        )
        XCTAssertTrue(font.items.allSatisfy { $0.keyEquivalent.isEmpty })

        // Wide again: everything comes back, and with nothing hidden there's no » button.
        bar.fit(width: 1400)
        XCTAssertEqual(bar.hiddenGroups, [])
        XCTAssertTrue(FormatBarViewController.overflowMenus(for: bar.hiddenGroups).isEmpty)
    }

    func testFormatBarGroupsFitFromTheLeftLeavingRoomForTheOverflowButton() {
        let widths: [CGFloat] = [100, 100, 100]
        let s = FormatBarViewController.spacing
        // All three fit without the » button.
        XCTAssertEqual(FormatBarViewController.groupsThatFit(widths: widths, overflowWidth: 30, in: 300 + 2 * s), 3)
        // One point less: the third goes, and the first two leave room for the » button.
        XCTAssertEqual(FormatBarViewController.groupsThatFit(widths: widths, overflowWidth: 30, in: 299 + 2 * s), 2)
        XCTAssertEqual(FormatBarViewController.groupsThatFit(widths: widths, overflowWidth: 30, in: 230), 1)
        XCTAssertEqual(FormatBarViewController.groupsThatFit(widths: widths, overflowWidth: 30, in: 50), 0)
    }

    func testFormatBarReflectsZoomAndFonts() {
        let bar = FormatBarViewController()
        bar.showZoom(1.25)
        XCTAssertEqual(bar.model.zoomSelection, 1.25)
        XCTAssertEqual(bar.model.zoomLevels, EditorViewController.zoomLevels)
        // A pinch can land between the levels: that zoom is listed while it lasts.
        bar.showZoom(1.1)
        XCTAssertEqual(bar.model.zoomSelection, 1.1)
        XCTAssertTrue(bar.model.zoomLevels.contains(1.1))
        bar.showZoom(0.8, fits: true)
        XCTAssertEqual(bar.model.zoomSelection, EditorViewController.fitZoomItem)
        XCTAssertEqual(bar.model.zoomLevels, EditorViewController.zoomLevels)

        // A font the document names but this Mac doesn't have is shown anyway.
        var format = SelectionFormat()
        format.fontFamily = "No Such Font Family"
        bar.update(format, bridge: AttributedStringBridge(styles: StyleSheet()), editable: false)
        XCTAssertEqual(bar.model.missingFamily, "No Such Font Family")
        XCTAssertFalse(bar.model.editable)
        format.fontFamily = FormatBarModel.installedFamilies.first
        bar.update(format, bridge: AttributedStringBridge(styles: StyleSheet()), editable: true)
        XCTAssertNil(bar.model.missingFamily)
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
