import AppKit
import XCTest

@testable import Cartilla

/// The ruler shows only indent and tab markers, measured from the page's left margin.
@MainActor
final class RulerTests: XCTestCase {
    func testRulerHasNoAccessoryAndStartsAtTheMargin() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        defer { doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        let textView = try XCTUnwrap(doc.editor?.textView)
        window.makeFirstResponder(textView)
        textView.toggleRuler(nil)
        let ruler = try XCTUnwrap(textView.enclosingScrollView?.horizontalRulerView)
        XCTAssertTrue(textView.isRulerVisible)
        XCTAssertNil(ruler.accessoryView, "AppKit's ruler accessory duplicates the format bar")
        let canvas = try XCTUnwrap(textView.superview)
        XCTAssertEqual(ruler.originOffset, textView.frame.minX + textView.textContainerOrigin.x, accuracy: 0.5)
        _ = canvas
        textView.toggleRuler(nil)
        XCTAssertFalse(textView.isRulerVisible)
    }
}
