import AppKit
import CartillaDocx
import XCTest

@testable import Cartilla

@MainActor
final class CartillaDocumentTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    func openDocument(_ fixture: String) throws -> (CartillaDocument, URL, Data) {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(fixture))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(fixture)")
        try data.write(to: url)
        let doc = try CartillaDocument(contentsOf: url, ofType: CartillaDocument.docxType)
        doc.makeWindowControllers()
        return (doc, url, data)
    }

    func save(_ doc: CartillaDocument, to url: URL, _ op: NSDocument.SaveOperationType = .saveToOperation) throws {
        let done = expectation(description: "saved")
        var failure: Error?
        doc.save(to: url, ofType: CartillaDocument.docxType, for: op) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
    }

    func testAutosavesInPlace() {
        XCTAssertTrue(CartillaDocument.autosavesInPlace)
    }

    func testOpeningShowsTextWithoutMarkingTheDocumentEdited() throws {
        let (doc, _, _) = try openDocument("08-spanish.docx")
        let text = try XCTUnwrap(doc.editor?.textView.string)
        XCTAssertTrue(text.contains("¿Qué tal? ¡Muy bien!"))
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.saveState, .saved)
        XCTAssertTrue(doc.editor?.textView.isEditable ?? false)
    }

    func testSaveWritesEditsAndKeepsEveryOtherPart() throws {
        let (doc, _, original) = try openDocument("10-word-features.docx")
        let tv = try XCTUnwrap(doc.editor?.textView)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("Edited in Cartilla. ", replacementRange: tv.selectedRange())
        // The edit registers with the document's undo manager; NSDocument counts it as a change when the
        // event loop closes the undo group (covered end to end by PersistenceUITests).
        XCTAssertTrue(tv.undoManager === doc.undoManager)
        XCTAssertTrue(doc.undoManager?.canUndo ?? false)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).docx")
        try save(doc, to: out)
        let written = try Data(contentsOf: out)
        let back = try OOXMLCodec().read(written)
        XCTAssertTrue(back.body.plainText.hasPrefix("Edited in Cartilla. Word-only features"))

        let before = try OPCPackage(data: original)
        let after = try OPCPackage(data: written)
        XCTAssertEqual(after.partNames, before.partNames)
        for part in before.parts where part.name != "word/document.xml" {
            XCTAssertEqual(after[part.name], part.data, "\(part.name) changed")
        }
        // Only the edited paragraph differs inside document.xml.
        let originalBody = try OOXMLCodec().read(original).body
        let changed = zip(originalBody.blocks, back.body.blocks).filter { $0.serialized() != $1.serialized() }
        XCTAssertEqual(changed.count, 1)
    }

    func testNewDocumentStartsFromTheBlankTemplateAndSaves() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        let tv = try XCTUnwrap(doc.editor?.textView)
        tv.insertText("Hola, Cartilla", replacementRange: NSRange(location: 0, length: 0))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).docx")
        try save(doc, to: out)
        let back = try OOXMLCodec().read(try Data(contentsOf: out))
        XCTAssertEqual(back.body.plainText, "Hola, Cartilla")
    }

    func testDocumentWindowHasAUsableSize() throws {
        let doc = CartillaDocument()
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 480)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, 320)
    }

    func testEditorUsesPageWidthColumn() {
        let editor = EditorViewController()
        editor.loadView()
        // The text view is the page's text column; the canvas draws the page and its margins.
        XCTAssertEqual(editor.textView.frame.width, PageSetup.letter.textWidth)
        XCTAssertEqual(editor.textView.textContainerInset.width, 0)
        XCTAssertEqual(editor.textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertTrue(editor.textView.allowsUndo)
    }

    func testOpaqueContentIsEditedWholeOrNotAtAll() throws {
        let text = NSMutableAttributedString(string: "Go to ")
        let link = NSAttributedString(string: "example", attributes: [.cartillaOpaque: NSObject()])
        text.append(link)
        text.append(NSAttributedString(string: " now"))
        let allowed = EditorViewController.editIsAllowed
        XCTAssertTrue(allowed(NSRange(location: 6, length: 0), text), "typing right before the link")
        XCTAssertTrue(allowed(NSRange(location: 13, length: 0), text), "typing right after the link")
        XCTAssertFalse(allowed(NSRange(location: 9, length: 0), text), "typing inside the link")
        XCTAssertFalse(allowed(NSRange(location: 12, length: 2), text), "deleting part of the link")
        XCTAssertTrue(allowed(NSRange(location: 6, length: 7), text), "deleting the whole link")
        XCTAssertTrue(allowed(NSRange(location: 0, length: 3), text), "editing plain text")
    }
}

final class OriginalsStoreTests: XCTestCase {
    func testKeepsOneCopyPerContentAndPrunesOldOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("originals-\(UUID())")
        let store = OriginalsStore(directory: dir)
        let file = URL(fileURLWithPath: "/tmp/Report.docx")
        let old = Date(timeIntervalSinceNow: -40 * 24 * 3600)
        try store.keepOriginal(Data("v1".utf8), of: file, now: old)
        try store.keepOriginal(Data("v1".utf8), of: file)  // identical: not kept twice
        try store.keepOriginal(Data("v2".utf8), of: file)
        XCTAssertEqual(store.entries().count, 2)
        let (latest, url) = try XCTUnwrap(store.latestOriginal(of: file))
        XCTAssertEqual(try Data(contentsOf: url), Data("v2".utf8))
        XCTAssertEqual(latest.originalPath, file.path)

        store.prune()
        XCTAssertEqual(store.entries().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)  // file + index
    }
}
