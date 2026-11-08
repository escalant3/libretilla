import AppKit
import Foundation
import Testing

@testable import LibretillaDocx

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
        #expect(pictures.allSatisfy { l.text.attribute(.libretillaOpaque, at: $0.0, effectiveRange: nil) != nil })
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

    // MARK: - Format ▸ Picture…

    func reformat(_ l: Loaded, at index: Int, _ change: (inout PictureFormat) -> Void) throws {
        let picture = try #require(l.bridge.editablePicture(in: l.text, at: index))
        var format = picture.format
        change(&format)
        let attrs = try #require(l.bridge.attributes(for: picture, format: format))
        l.text.addAttributes(attrs, range: picture.range)
    }

    @Test func documentPictureFormatIsSavedAndReopened() throws {
        let original = try Corpus.data("05-images.docx")
        let l = try load(original)
        let pictures = attachments(in: l.text).filter { $0.1.image?.accessibilityDescription == nil }
        let first = try #require(pictures.first)
        try reformat(l, at: first.0) {
            $0.size = CGSize(width: 192, height: 72)
            $0.rotation = 90
            $0.brightness = 0.2
            $0.contrast = -0.3
            $0.opacity = 0.5
        }
        // Shown turned: the room it takes on the line is its rotated size.
        let shown = try #require(l.text.attribute(.attachment, at: first.0, effectiveRange: nil) as? NSTextAttachment)
        #expect(shown.bounds.size == CGSize(width: 72, height: 192))

        let (back, out, notices) = try save(l)
        #expect(notices.isEmpty)
        let xml = documentXML(back)
        #expect(xml.contains(#"<wp:extent cx="2438400" cy="914400"/>"#))
        #expect(xml.contains(#"rot="5400000""#))
        #expect(xml.contains(#"<a:lum bright="20000" contrast="-30000"/>"#))
        #expect(xml.contains(#"<a:alphaModFix amt="50000"/>"#))
        // The other picture is untouched.
        let before = String(decoding: try codec.read(original).body.serialized(), as: UTF8.self)
        let drawings = before.matches(of: /<w:drawing>.*?<\/w:drawing>/).map { String($0.output) }
        #expect(drawings.count == 2)
        #expect(!xml.contains(drawings[0]))
        #expect(xml.contains(drawings[1]))

        let reopened = try load(out)
        let picture = try #require(reopened.bridge.editablePicture(in: reopened.text, at: first.0))
        #expect(
            picture.format
                == PictureFormat(
                    size: CGSize(width: 192, height: 72), rotation: 90, brightness: 0.2, contrast: -0.3, opacity: 0.5))

        // Back to plain: the effects go away again.
        try reformat(reopened, at: first.0) { $0 = PictureFormat(size: $0.size) }
        let plain = documentXML(try save(reopened).0)
        #expect(!plain.contains("a:lum"))
        #expect(!plain.contains("alphaModFix"))
        #expect(!plain.contains("rot="))
    }

    @Test func insertedPictureCanBeFormattedBeforeSaving() throws {
        let l = try load("01-plain.docx")
        let data = Self.png(width: 200, height: 100)
        let picture = try #require(
            AttributedStringBridge.picture(data: data, filename: "chart.png", maxWidth: 1000, attributes: [:]))
        l.text.insert(picture, at: 0)
        try reformat(l, at: 0) {
            $0.size = CGSize(width: 100, height: 100)
            $0.rotation = 45
        }
        let (back, out, notices) = try save(l)
        #expect(notices.isEmpty)
        #expect(try OPCPackage(data: out)["word/media/image1.png"] == data)
        let xml = documentXML(back)
        #expect(xml.contains(#"<wp:extent cx="1270000" cy="1270000"/>"#))
        #expect(xml.contains(#"rot="2700000""#))
        // √2 × 100 pt wide when turned 45°: 20.71 pt more on each side.
        #expect(xml.contains(#"<wp:effectExtent l="263023" t="263023" r="263023" b="263023"/>"#))
        #expect(!xml.contains(OpaqueInline.relationshipPlaceholder))
    }

    @Test func boundingSizeOfRotatedPictures() {
        var f = PictureFormat(size: CGSize(width: 40, height: 10))
        #expect(f.boundingSize == CGSize(width: 40, height: 10))
        f.rotation = 90
        #expect(f.boundingSize == CGSize(width: 10, height: 40))
        f.rotation = 180
        #expect(f.boundingSize == CGSize(width: 40, height: 10))
        #expect(PictureFormat.normalized(-90) == 270)
    }
}
