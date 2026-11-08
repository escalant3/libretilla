import Foundation

/// The picture in a DrawingML drawing (`wp:inline` or `wp:anchor` with one `a:blip r:embed`).
public struct ImageReference: Sendable, Equatable {
    public var relationshipId: String
    /// Displayed size in points, from `wp:extent` (EMU; 12700 per point).
    public var size: CGSize
    /// The drawing floats (`wp:anchor`); Libretilla shows it inline where it's anchored.
    public var isFloating: Bool
    /// Its rotation, brightness, contrast and opacity (and `size` again).
    public var format: PictureFormat

    static let emuPerPoint: CGFloat = 12700

    init?(drawing e: RawXML.Element) {
        let drawings = e.descendants(named: "w:drawing")
        guard drawings.count == 1, let frame = drawings[0].childElements.first,
            frame.name == "wp:inline" || frame.name == "wp:anchor"
        else { return nil }
        let blips = frame.descendants(named: "a:blip")
        guard blips.count == 1, let id = blips[0].attribute("r:embed"),
            let extent = frame.firstChild(named: "wp:extent"),
            let cx = extent.attribute("cx").flatMap(Double.init), let cy = extent.attribute("cy").flatMap(Double.init),
            cx > 0, cy > 0
        else { return nil }
        relationshipId = id
        size = CGSize(width: CGFloat(cx) / Self.emuPerPoint, height: CGFloat(cy) / Self.emuPerPoint)
        isFloating = frame.name == "wp:anchor"
        format = PictureFormat(frame: frame, size: size)
    }
}

/// Image bytes for a picture inserted in Libretilla, and its file extension (`png`, `jpeg`, `gif`).
public struct NewMedia: Sendable {
    public var data: Data
    public var fileExtension: String
}

extension OpaqueInline {
    static let relationshipPlaceholder = "libretilla-new-image"
    static let drawingIdPlaceholder = "4294967295"

    /// A new inline picture, as Word writes one: `w:r` › `w:drawing` › `wp:inline` with a `pic:pic`.
    /// `runProperties` is the run's `w:rPr`, if any. The relationship and drawing id are filled in on save.
    public static func newPicture(
        _ media: NewMedia, size: CGSize, name: String, runProperties: Data? = nil
    ) -> OpaqueInline {
        let cx = Int((size.width * ImageReference.emuPerPoint).rounded())
        let cy = Int((size.height * ImageReference.emuPerPoint).rounded())
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
        let n = RawXML.escapeAttribute(name)
        let id = drawingIdPlaceholder
        var xml = "<w:r>"
        if let runProperties { xml += String(decoding: runProperties, as: UTF8.self) }
        xml +=
            "<w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"\(n)\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a=\"\(a)\" noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic xmlns:a=\"\(a)\"><a:graphicData uri=\"\(pic)\">"
            + "<pic:pic xmlns:pic=\"\(pic)\"><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\(n)\"/><pic:cNvPicPr/>"
            + "</pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(relationshipPlaceholder)\"/>"
            + "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
            + "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        let data = Data(xml.utf8)
        // Parse what we built so the inline is like any other (display, image size).
        let doc = try! RawXML.Document(data: data, part: "new picture")
        var inline = OpaqueInline(parsing: doc.root, in: doc)
        inline.newMedia = media
        return inline
    }
}

// MARK: - Writing new pictures

extension OOXMLCodec {
    static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static let wordprocessingDrawingNamespace =
        "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

    static func contentType(forImageExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpeg", "jpg": "image/jpeg"
        case "gif": "image/gif"
        default: "image/\(ext)"
        }
    }

    /// Stores every picture inserted in Libretilla as a media part with a relationship, and gives its
    /// drawing a unique id. Identical images inserted twice share one part.
    static func resolveNewPictures(in body: inout DocumentBody, package: inout OPCPackage, part: String) throws {
        var nextDrawingId: Int?
        var byContent: [Data: String] = [:]
        for (b, block) in body.blocks.enumerated() {
            guard case .paragraph(var p) = block else { continue }
            var changed = false
            for (i, inline) in p.inlines.enumerated() {
                guard case .opaque(var o) = inline, let media = o.newMedia else { continue }
                if nextDrawingId == nil {
                    nextDrawingId = (maxDrawingId(in: body.serialized()) ?? 0) + 1
                }
                let rid: String
                if let existing = byContent[media.data] {
                    rid = existing
                } else {
                    let name = package.unusedPartName(folder: "word/media", stem: "image", ext: media.fileExtension)
                    package.setPart(name, data: media.data)
                    try package.ensureDefaultContentType(
                        extension: media.fileExtension, contentType: contentType(forImageExtension: media.fileExtension)
                    )
                    rid = try package.addRelationship(
                        of: part, type: imageType, target: String(name.dropFirst("word/".count)), external: false)
                    byContent[media.data] = rid
                }
                var xml = String(decoding: o.xml, as: UTF8.self)
                xml = xml.replacingOccurrences(of: OpaqueInline.relationshipPlaceholder, with: rid)
                xml = xml.replacingOccurrences(
                    of: "id=\"\(OpaqueInline.drawingIdPlaceholder)\"", with: "id=\"\(nextDrawingId!)\"")
                nextDrawingId! += 1
                o.xml = Data(xml.utf8)
                o.newMedia = nil
                p.inlines[i] = .opaque(o)
                changed = true
            }
            if changed { body.blocks[b] = .paragraph(p) }
        }
        if nextDrawingId != nil {
            body.declareNamespace("r", relationshipsNamespace)
            body.declareNamespace("wp", wordprocessingDrawingNamespace)
        }
    }

    /// The largest `wp:docPr` id in use (they must be unique in a document).
    static func maxDrawingId(in xml: Data) -> Int? {
        let s = String(decoding: xml, as: UTF8.self)
        var best: Int?
        var search = s.startIndex..<s.endIndex
        while let r = s.range(of: "<wp:docPr ", range: search) {
            let end = s[r.upperBound...].firstIndex(of: ">") ?? s.endIndex
            let tag = s[r.upperBound..<end]
            if let idRange = tag.range(of: #"(?<![A-Za-z:])id="(\d+)""#, options: .regularExpression) {
                let digits = tag[idRange].filter(\.isNumber)
                if let n = Int(digits), String(n) != OpaqueInline.drawingIdPlaceholder { best = max(best ?? 0, n) }
            }
            search = end..<s.endIndex
        }
        return best
    }
}

extension OPCPackage {
    /// `folder/stemN.ext` for the first N ≥ 1 not in use.
    func unusedPartName(folder: String, stem: String, ext: String) -> String {
        var n = 1
        while self["\(folder)/\(stem)\(n).\(ext)"] != nil { n += 1 }
        return "\(folder)/\(stem)\(n).\(ext)"
    }

    /// Adds `<Default Extension="ext" ContentType="…"/>` to `[Content_Types].xml` unless it has one.
    mutating func ensureDefaultContentType(extension ext: String, contentType: String) throws {
        let name = "[Content_Types].xml"
        guard let types = self[name] else { throw DocxCodecError.missingPart(name) }
        let root = try RawXML.Document(data: types, part: name).root
        let known = root.childElements(named: "Default").contains {
            $0.attribute("Extension")?.lowercased() == ext.lowercased()
        }
        guard !known else { return }
        let element =
            "<Default Extension=\"\(RawXML.escapeAttribute(ext))\" ContentType=\"\(RawXML.escapeAttribute(contentType))\"/>"
        setPart(name, data: try Self.appending(element, toRootOf: types, part: name))
    }
}
