import AppKit
import CoreImage
import UniformTypeIdentifiers

// Pictures: the document's own show as images; any other attachment becomes a new picture on save.

extension AttributedStringBridge {
    /// The image a drawing shows, at its Word size, or nil if it isn't a picture Libretilla can show.
    func pictureAttachment(_ inline: OpaqueInline) -> NSTextAttachment? {
        guard let ref = inline.image, let data = images[ref.relationshipId], let image = NSImage(data: data) else {
            return nil
        }
        return Self.pictureAttachment(image, format: ref.format)
    }

    /// An attachment showing `source` as `format` says.
    static func pictureAttachment(_ source: NSImage, format: PictureFormat) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let identity = format.rotation == 0 && !format.isAdjusted
        attachment.image = identity ? source : rendered(source, format: format)
        attachment.bounds = NSRect(origin: .zero, size: identity ? format.size : format.boundingSize)
        return attachment
    }

    /// `source` drawn as `format` says, at its rotated bounding size.
    public static func rendered(_ source: NSImage, format: PictureFormat) -> NSImage {
        let adjusted = adjusted(source, brightness: format.brightness, contrast: format.contrast) ?? source
        let bound = format.boundingSize
        let image = NSImage(size: bound, flipped: false) { _ in
            let t = NSAffineTransform()
            t.translateX(by: bound.width / 2, yBy: bound.height / 2)
            // DrawingML turns clockwise; AppKit's y axis points up, so that's a negative angle here.
            t.rotate(byDegrees: -format.rotation)
            t.concat()
            let rect = NSRect(
                x: -format.size.width / 2, y: -format.size.height / 2, width: format.size.width,
                height: format.size.height)
            adjusted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: format.opacity)
            return true
        }
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }

    /// `source` with brightness and contrast changed (Core Image's colour controls), or nil if unchanged.
    static func adjusted(_ source: NSImage, brightness: CGFloat, contrast: CGFloat) -> NSImage? {
        guard brightness != 0 || contrast != 0,
            let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let filter = CIFilter(name: "CIColorControls")
        else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        // DrawingML contrast −100 %…100 % goes from flat grey to (nearly) black and white.
        let factor = contrast >= 0 ? 1 / (1 - min(contrast, 0.95)) : 1 + contrast
        filter.setValue(factor, forKey: kCIInputContrastKey)
        filter.setValue(1, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
            let result = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        else { return nil }
        return NSImage(cgImage: result, size: source.size)
    }

    // MARK: - Format ▸ Picture…

    /// A picture in the text that Format ▸ Picture… can change.
    public struct EditablePicture {
        /// The picture's object character.
        public let range: NSRange
        /// How it shows now.
        public let format: PictureFormat
        /// Its image as stored, before rotation and adjustments.
        public let source: NSImage
        /// Its natural size in points (the image's own).
        public var naturalSize: CGSize { source.size }
        let inline: OpaqueInline
    }

    /// The picture at character `index`: the document's own or one inserted, pasted or dropped.
    public func editablePicture(in text: NSAttributedString, at index: Int) -> EditablePicture? {
        guard index >= 0, index < text.length,
            let attachment = text.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        else { return nil }
        let range = NSRange(location: index, length: 1)
        let attrs = text.attributes(at: index, effectiveRange: nil)
        guard attrs[.libretillaBlock] == nil, attrs[.libretillaPageBreak] == nil else { return nil }
        if let box = attrs[.libretillaOpaque] as? OpaqueInlineBox {
            guard let ref = box.inline.image,
                let data = box.inline.newMedia?.data ?? images[ref.relationshipId],
                let source = NSImage(data: data), box.inline.formattingPicture(ref.format) != nil
            else { return nil }
            return EditablePicture(range: range, format: ref.format, source: source, inline: box.inline)
        }
        // Not saved yet: becomes a new drawing now, so its format can be written into it.
        guard let inline = Self.newPicture(from: attachment, runFormat: attrs[.libretillaRun] as? RunFormat),
            let ref = inline.image, let data = inline.newMedia?.data, let source = NSImage(data: data)
        else { return nil }
        return EditablePicture(range: range, format: ref.format, source: source, inline: inline)
    }

    /// The attributes that show `picture` as `format` and save it so (`.attachment` and `.libretillaOpaque`),
    /// or nil if its drawing can't take the format.
    public func attributes(for picture: EditablePicture, format: PictureFormat) -> [NSAttributedString.Key: Any]? {
        guard let inline = picture.inline.formattingPicture(format) else { return nil }
        return [
            .attachment: Self.pictureAttachment(picture.source, format: format),
            .libretillaOpaque: OpaqueInlineBox(inline),
        ]
    }

    /// The bytes and file extension to store for an attachment's image.
    static func media(of attachment: NSTextAttachment) -> NewMedia? {
        // `fileWrapper` only when there are no `contents`: asking a data attachment for one makes AppKit
        // rebuild it, which can pull its image from under TextKit while it's on screen.
        let data =
            attachment.contents
            ?? attachment.fileWrapper.flatMap { $0.isRegularFile ? $0.regularFileContents : nil }
        // The bytes say what they are more reliably than an attachment's declared type.
        if let data, let ext = sniffedImageExtension(data) {
            return NewMedia(data: data, fileExtension: ext)
        }
        // Convert (HEIC, TIFF, PDF, a pasted image without bytes…) to PNG.
        guard let image = attachment.image ?? data.flatMap(NSImage.init(data:)),
            let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return NewMedia(data: png, fileExtension: "png")
    }

    /// `png`, `jpeg` or `gif` from the file signature; nil for anything else.
    static func sniffedImageExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) { return "gif" }
        return nil
    }

    /// The size an attachment shows at: its bounds if set, else its image's size.
    static func displaySize(of attachment: NSTextAttachment, media: NewMedia? = nil) -> CGSize? {
        if attachment.bounds.width > 0, attachment.bounds.height > 0 { return attachment.bounds.size }
        if let size = attachment.image?.size, size.width > 0, size.height > 0 { return size }
        if let data = media?.data, let size = NSImage(data: data)?.size, size.width > 0 { return size }
        return nil
    }

    static func newPicture(from attachment: NSTextAttachment, runFormat: RunFormat?) -> OpaqueInline? {
        guard let media = media(of: attachment), let size = displaySize(of: attachment, media: media) else {
            return nil
        }
        // A dropped file keeps its name; AppKit names other attachments "Attachment.ext".
        let name = attachment.contents == nil ? (attachment.fileWrapper?.preferredFilename ?? "Picture") : "Picture"
        return OpaqueInline.newPicture(media, size: size, name: name, runProperties: runFormat?.xml)
    }

    /// A new picture to insert: `data` (any image format) shown `maxWidth` points wide at most. `filename`
    /// only tells its type.
    public static func picture(
        data: Data, filename: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]
    )
        -> NSAttributedString?
    {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        // From the bytes (setting `image` would make AppKit re-encode them); TextKit draws from these.
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .image
        let attachment = NSTextAttachment(data: data, ofType: type.identifier)
        attachment.bounds = NSRect(origin: .zero, size: fitted(image.size, maxWidth: maxWidth))
        var attrs = attributes
        for key in NSAttributedString.Key.libretillaNonInheritable { attrs[key] = nil }
        attrs[.attachment] = attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
    }

    /// `size` scaled down (keeping its proportions) to at most `maxWidth` wide.
    public static func fitted(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > maxWidth, maxWidth > 0 else { return size }
        return CGSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded())
    }
}
