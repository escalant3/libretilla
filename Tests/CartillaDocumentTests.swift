import XCTest

@testable import Cartilla

@MainActor
final class CartillaDocumentTests: XCTestCase {
    func testAutosavesInPlace() {
        XCTAssertTrue(CartillaDocument.autosavesInPlace)
    }

    func testEditorUsesPageWidthColumn() {
        let editor = EditorViewController()
        editor.loadView()
        XCTAssertEqual(editor.textView.frame.width, EditorViewController.pageWidth)
        XCTAssertTrue(editor.textView.allowsUndo)
    }
}
