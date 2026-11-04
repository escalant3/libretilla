import AppKit
import Foundation
import Testing

@testable import CartillaDocx

@MainActor
@Suite struct PictureTests {
    let codec = OOXMLCodec()

    struct Loaded {
        var doc: DocxDocument
        var bridge: AttributedStringBridge
        var text: NSMutableAttributedString
    }

    func load(_ name: String) throws -> Loaded { try load(try Corpus.data(name)) }

    func load(_ data: Data) throws -> Loaded {
        let doc = try codec.read(data)
        let bridge = AttributedStringBridge(doc)
        return Loaded(
            doc: doc, bridge: bridge,
            text: NSMutableAttributedString(attributedString: bridge.attributedString(for: doc.body)))
    }

    /// Saves twice from the same base, as autosave does; both must give the same file.
    func save(_ l: Loaded) throws -> (DocxDocument, Data, [String]) {
        var out = l.doc
        let result = l.bridge.body(from: l.text, base: l.doc.body)
        out.body = result.body
        let first = try codec.write(out)
        let data = try codec.write(out)
        #expect(first == data)
        #expect(try PackageChecker.problems(data).isEmpty)
        return (try codec.read(data), data, result.notices)
    }

    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func attachments(in text: NSAttributedString) -> [(Int, NSTextAttachment)] {
        var out: [(Int, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            if let a = v as? NSTextAttachment { out.append((r.location, a)) }
        }
        return out
    }

    func documentXML(_ doc: DocxDocument) -> String { String(decoding: doc.body.serialized(), as: UTF8.self) }

    @Test func documentPicturesShowAtTheirWordSize() throws {
        let l = try load("05-images.docx")
        let pictures = attachments(in: l.text).filter { $0.1.image?.accessibilityDescription == nil }
        #expect(pictures.count == 2)
        // 128 × 96 px at 96 dpi = 96 × 72 pt; 240 × 160 px = 180 × 120 pt.
        #expect(pictures[0].1.bounds.size == CGSize(width: 96, height: 72))
        #expect(pictures[1].1.bounds.size == CGSize(width: 180, height: 120))
        #expect(pictures.allSatisfy { l.text.attribute(.cartillaOpaque, at: $0.0, effectiveRange: nil) != nil })
    }

    @Test func untouchedPicturesKeepTheirBytes() throws {
        let original = try Corpus.data("05-images.docx")
        let l = try load(original)
        l.text.replaceCharacters(in: NSRange(location: 0, length: 6), with: "Imágenes")
        let (back, _, _) = try save(l)
        let before = String(decoding: try codec.read(original).body.serialized(), as: UTF8.self)
        let drawing = try #require(before.range(of: "<w:drawing>.*?</w:drawing>", options: .regularExpression))
        #expect(documentXML(back).contains(before[drawing]))
    }

    @Test func insertedPictureIsSavedAsWordWritesIt() throws {
        let l = try load("01-plain.docx")
        let data = Self.png(width: 200, height: 100)
        let picture = try #require(
            AttributedStringBridge.picture(data: data, filename: "chart.png", maxWidth: 1000, attributes: [:]))
        l.text.insert(picture, at: 0)
        let (back, out, notices) = try save(l)
        #expect(notices.isEmpty)

        let package = try OPCPackage(data: out)
        let rel = try #require(
            try package.relationships(of: "word/document.xml").first { $0.type == OOXMLCodec.imageType })
        #expect(rel.resolvedPartName == "word/media/image1.png")
        #expect(package["word/media/image1.png"] == data)
        let types = String(decoding: try #require(package["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains(#"<Default Extension="png" ContentType="image/png"/>"#))

        let xml = documentXML(back)
        #expect(xml.contains("<a:blip r:embed=\"\(rel.id)\"/>"))
        #expect(xml.contains(#"<wp:docPr id="1" name="Picture"/>"#))
        #expect(xml.contains(#"<wp:extent cx="2540000" cy="1270000"/>"#))  // 200 × 100 pt
        #expect(xml.contains("xmlns:wp="))

        // Reopened, it's a picture with its image.
        let reopened = try load(out)
        let shown = try #require(attachments(in: reopened.text).first)
        #expect(shown.1.bounds.size == CGSize(width: 200, height: 100))
        #expect(shown.1.image != nil)
        // The inserted attachment displays before saving too.
        #expect(
            picture.attribute(.attachment, at: 0, effectiveRange: nil).map { ($0 as! NSTextAttachment).contents } != nil
        )
    }

    @Test func drawingIdsStayUniqueAndIdenticalImagesShareAPart() throws {
        let l = try load("05-images.docx")  // has docPr ids 1 and 2
        let data = Self.png(width: 10, height: 10)
        for _ in 0..<2 {
            let p = try #require(
                AttributedStringBridge.picture(data: data, filename: "dot.png", maxWidth: 100, attributes: [:]))
            l.text.insert(p, at: 0)
        }
        let (back, out, _) = try save(l)
        let xml = documentXML(back)
        for id in 1...4 { #expect(xml.contains("<wp:docPr id=\"\(id)\"")) }
        let media = try OPCPackage(data: out).partNames.filter { $0.hasPrefix("word/media/") }
        #expect(media.count == 3)
    }

    @Test func picturesInOtherFormatsAreStoredAsPNG() throws {
        let png = Self.png(width: 20, height: 20)
        let tiff = try #require(NSImage(data: png)?.tiffRepresentation)
        let attachment = NSTextAttachment(data: tiff, ofType: "public.tiff")
        let media = try #require(AttributedStringBridge.media(of: attachment))
        #expect(media.fileExtension == "png")
        #expect(NSImage(data: media.data) != nil)

        let jpegAttachment = NSTextAttachment(data: Data([0xFF, 0xD8, 0xFF]), ofType: "public.jpeg")
        #expect(AttributedStringBridge.media(of: jpegAttachment)?.fileExtension == "jpeg")
    }

    @Test func largePicturesAreFittedToTheTextWidth() {
        #expect(
            AttributedStringBridge.fitted(CGSize(width: 1000, height: 500), maxWidth: 400)
                == CGSize(width: 400, height: 200))
        #expect(
            AttributedStringBridge.fitted(CGSize(width: 100, height: 50), maxWidth: 400)
                == CGSize(width: 100, height: 50))
    }

    @Test func deletingAPictureRemovesItsDrawing() throws {
        let l = try load("05-images.docx")
        let first = try #require(attachments(in: l.text).first)
        l.text.deleteCharacters(in: NSRange(location: first.0, length: 1))
        let (back, _, _) = try save(l)
        #expect(documentXML(back).components(separatedBy: "<w:drawing>").count == 2)
    }
}
