import AppKit
import LibretillaDocx
import XCTest

@testable import Libretilla

/// Pictures (M3) through the real editor, undo and save path.
@MainActor
final class PictureCommandTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/generated")

    var scratch: URL!
    var doc: LibretillaDocument!
    var tv: LibretillaTextView { doc.editor!.textView }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libretilla-pictures-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("01-plain.docx")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("01-plain.docx"), to: url)
        doc = try LibretillaDocument(contentsOf: url, ofType: LibretillaDocument.docxType)
        doc.makeWindowControllers()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func saved() throws -> (DocxDocument, OPCPackage) {
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
        return (try OOXMLCodec().read(data), try OPCPackage(data: data))
    }

    static func image(width: Int, height: Int, type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: [:])!
    }

    func attachment(at location: Int) -> NSTextAttachment? {
        tv.textStorage?.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment
    }

    func testInsertedImageIsFittedSavedAndUndoable() throws {
        let file = scratch.appendingPathComponent("wide.png")
        let png = Self.image(width: 1200, height: 600, type: .png)
        try png.write(to: file)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        try doc.editor!.insertImage(contentsOf: file)

        let shown = try XCTUnwrap(attachment(at: 0))
        XCTAssertEqual(shown.bounds.width, PageSetup.letter.textWidth, accuracy: 0.5)
        XCTAssertEqual(shown.bounds.height, PageSetup.letter.textWidth / 2, accuracy: 1)

        let (back, package) = try saved()
        XCTAssertEqual(package["word/media/image1.png"], png)
        XCTAssertTrue(String(decoding: back.body.serialized(), as: UTF8.self).contains("<wp:inline"))

        doc.undoManager?.undo()
        XCTAssertNil(attachment(at: 0))
        XCTAssertFalse(try saved().1.partNames.contains("word/media/image1.png"))
    }

    func testPastedImageIsFittedAndSavedAsPNG() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("libretilla-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Self.image(width: 2000, height: 1000, type: .tiff), forType: .tiff)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(tv.readSelection(from: pasteboard, type: .tiff))

        let shown = try XCTUnwrap(attachment(at: 0))
        XCTAssertLessThanOrEqual(shown.bounds.width, PageSetup.letter.textWidth + 0.5)
        let (_, package) = try saved()
        let media = package.partNames.filter { $0.hasPrefix("word/media/") }
        XCTAssertEqual(media, ["word/media/image1.png"])
    }
}
