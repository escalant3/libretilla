import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// Links (M3) through the real editor, undo and save path.
@MainActor
final class LinkCommandTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!
    var doc: LibretillaDocument!
    var editor: EditorViewController { doc.editor! }
    var tv: LibretillaTextView { editor.textView }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-links-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func open(_ fixture: String) throws {
        let url = scratch.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)
        doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        doc.makeWindowControllers()
    }

    func saved() throws -> (DocxDocument, Data) {
        let url = scratch.appendingPathComponent("\(UUID()).docx")
        let done = expectation(description: "saved")
        var failure: Error?
        doc.save(to: url, ofType: LibretillaDocument.docxType, for: .saveToOperation) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        let data = try Data(contentsOf: url)
        return (try OOXMLCodec().read(data), data)
    }

    func range(of s: String) throws -> NSRange {
        let r = (tv.string as NSString).range(of: s)
        try XCTSkipIf(r.location == NSNotFound, "\(s) not found")
        return r
    }

    func url(at location: Int) -> String? {
        (tv.textStorage?.attribute(.link, at: location, effectiveRange: nil) as? URL)?.absoluteString
    }

    func testTypedURLsAreNormalized() {
        XCTAssertEqual(EditorViewController.normalizedURL("example.com"), "https://example.com")
        XCTAssertEqual(EditorViewController.normalizedURL(" https://a.b/c?d=1 "), "https://a.b/c?d=1")
        XCTAssertEqual(EditorViewController.normalizedURL("hola@libretilla.app"), "mailto:hola@libretilla.app")
        XCTAssertEqual(EditorViewController.normalizedURL("mailto:x@y.z"), "mailto:x@y.z")
        XCTAssertNil(EditorViewController.normalizedURL("two words"))
        XCTAssertNil(EditorViewController.normalizedURL(""))
    }

    func testLinkingASelectionIsUndoableAndSaved() throws {
        try open("01-plain.docx")
        let r = try range(of: "plain paragraph")
        editor.applyLink("https://libretilla.app", to: r)
        XCTAssertEqual(url(at: r.location), "https://libretilla.app")
        // The Hyperlink character style colours it.
        let color = tv.textStorage?.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(color)

        let (back, data) = try saved()
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        XCTAssertTrue(xml.contains("<w:hyperlink r:id="))
        let rels = try OPCPackage(data: data).relationships(of: "word/document.xml").filter { $0.isExternal }
        XCTAssertEqual(rels.map(\.target), ["https://libretilla.app"])

        doc.undoManager?.undo()
        XCTAssertNil(url(at: r.location))
        XCTAssertFalse(String(decoding: try saved().0.body.serialized(), as: UTF8.self).contains("<w:hyperlink"))
    }

    func testTypingInsideALinkExtendsItButNotAtItsEnd() throws {
        try open("06-hyperlinks.docx")
        let r = try range(of: "example.com")
        tv.setSelectedRange(NSRange(location: r.location + 7, length: 0))  // example|.com
        tv.insertText("s", replacementRange: tv.selectedRange())
        XCTAssertEqual(
            (tv.string as NSString).substring(with: NSRange(location: r.location, length: 12)), "examples.com")
        XCTAssertNotNil(url(at: r.location + 7))

        tv.setSelectedRange(NSRange(location: r.location + 12, length: 0))  // after the link
        tv.insertText("!", replacementRange: tv.selectedRange())
        XCTAssertNil(url(at: r.location + 12))

        let (back, _) = try saved()
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        XCTAssertTrue(xml.contains("examples.com</w:t></w:r></w:hyperlink>"))
    }

    func testRemovingALinkKeepsItsText() throws {
        try open("06-hyperlinks.docx")
        let found = try XCTUnwrap(
            AttributedStringBridge.link(at: try range(of: "example.com").location, in: tv.textStorage!))
        editor.removeLink(in: found.range)
        XCTAssertNil(url(at: found.range.location))
        let (back, _) = try saved()
        XCTAssertTrue(back.body.plainText.contains("Visit example.com for details."))
    }

    func testInsertingALinkAtTheCaret() throws {
        try open("01-plain.docx")
        let at = try range(of: "plain paragraph").location
        editor.insertLink("Libretilla", url: "https://libretilla.app", at: NSRange(location: at, length: 0))
        XCTAssertEqual(url(at: at), "https://libretilla.app")
        let (back, _) = try saved()
        XCTAssertTrue(back.body.plainText.contains("This is a Libretillaplain paragraph"))
    }

    func testAPlainClickOnALinkPlacesTheCaret() throws {
        try open("06-hyperlinks.docx")
        let at = try range(of: "example.com").location + 3
        XCTAssertTrue(editor.textView(tv, clickedOnLink: URL(string: "https://example.com")!, at: at))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: at, length: 0))
    }
}
