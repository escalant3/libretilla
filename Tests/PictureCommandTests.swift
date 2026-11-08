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
        // Format Picture shows a real sheet, which puts the window on screen: close it with the document.
        if let window = doc?.editor?.view.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        doc?.close()
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

    // MARK: - Format ▸ Picture…

    func insertPicture(width: Int, height: Int) throws -> Data {
        let file = scratch.appendingPathComponent("\(UUID()).png")
        let png = Self.image(width: width, height: height, type: .png)
        try png.write(to: file)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        try doc.editor!.insertImage(contentsOf: file)
        // The test is one run-loop pass, so one undo group; end it as the end of a user event would.
        if let undo = doc.undoManager, undo.groupingLevel > 0 {
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
        }
        return png
    }

    func testFormatPictureResizesKeepingOrNotTheAspectRatio() throws {
        _ = try insertPicture(width: 200, height: 100)
        let editor = doc.editor!
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.pictureIndex(for: nil), 0)
        editor.formatPicture(nil)
        let sheet = try XCTUnwrap(editor.pictureFormatter)
        XCTAssertEqual(sheet.format.size, CGSize(width: 200, height: 100))

        sheet.setWidth(100)
        XCTAssertEqual(sheet.format.size, CGSize(width: 100, height: 50))
        // Shown while the sheet is open, but not an edit yet.
        XCTAssertEqual(attachment(at: 0)?.bounds.size, CGSize(width: 100, height: 50))
        XCTAssertFalse(doc.undoManager!.canUndo && doc.undoManager!.undoActionName == "Format Picture")

        sheet.keepAspectRatio.state = .off
        sheet.setHeight(80)
        XCTAssertEqual(sheet.format.size, CGSize(width: 100, height: 80))
        sheet.ok(nil)
        XCTAssertEqual(attachment(at: 0)?.bounds.size, CGSize(width: 100, height: 80))
        XCTAssertEqual(doc.undoManager?.undoActionName, "Format Picture")

        let xml = String(decoding: try saved().0.body.serialized(), as: UTF8.self)
        XCTAssertTrue(xml.contains(#"<wp:extent cx="1270000" cy="1016000"/>"#))

        doc.undoManager?.undo()
        XCTAssertEqual(attachment(at: 0)?.bounds.size, CGSize(width: 200, height: 100))
    }

    func testFormatPictureRotatesAndAdjustsAndCancelRestores() throws {
        let png = try insertPicture(width: 40, height: 20)
        let editor = doc.editor!
        editor.openPictureFormatter(at: 0)
        var sheet = try XCTUnwrap(editor.pictureFormatter)
        sheet.rotateRight(nil)
        XCTAssertEqual(sheet.format.rotation, 90)
        XCTAssertEqual(attachment(at: 0)?.bounds.size, CGSize(width: 20, height: 40))
        sheet.cancel(nil)
        XCTAssertEqual(attachment(at: 0)?.bounds.size, CGSize(width: 40, height: 20))

        editor.pictureFormatter = nil
        editor.openPictureFormatter(at: 0)
        sheet = try XCTUnwrap(editor.pictureFormatter)
        sheet.rotateLeft(nil)
        sheet.brightnessField.stringValue = "25"
        sheet.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: sheet.brightnessField))
        sheet.contrastSlider.doubleValue = -40
        sheet.contrastSlider.sendAction(sheet.contrastSlider.action, to: sheet.contrastSlider.target)
        sheet.opacitySlider.doubleValue = 60
        sheet.opacitySlider.sendAction(sheet.opacitySlider.action, to: sheet.opacitySlider.target)
        XCTAssertEqual(
            sheet.format,
            PictureFormat(
                size: CGSize(width: 40, height: 20), rotation: 270, brightness: 0.25, contrast: -0.4, opacity: 0.6))
        sheet.ok(nil)

        let (back, package) = try saved()
        XCTAssertEqual(package["word/media/image1.png"], png, "the image is stored as it was")
        let xml = String(decoding: back.body.serialized(), as: UTF8.self)
        XCTAssertTrue(xml.contains(#"rot="16200000""#))
        XCTAssertTrue(xml.contains(#"<a:lum bright="25000" contrast="-40000"/>"#))
        XCTAssertTrue(xml.contains(#"<a:alphaModFix amt="60000"/>"#))
    }

    func testFormatPictureIsOnlyForPictures() throws {
        let editor = doc.editor!
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(editor.pictureIndex(for: nil))
        let item = NSMenuItem(title: "", action: #selector(EditorViewController.formatPicture(_:)), keyEquivalent: "")
        XCTAssertFalse(editor.validateMenuItem(item))
        _ = try insertPicture(width: 10, height: 10)
        tv.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(editor.validateMenuItem(item))
    }
}
