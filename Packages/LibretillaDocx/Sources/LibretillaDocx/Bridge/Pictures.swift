import AppKit
import UniformTypeIdentifiers

// Pictures: the document's own show as images; any other attachment becomes a new picture on save.

extension AttributedStringBridge {
    /// The image a drawing shows, at its Word size, or nil if it isn't a picture Libretilla can show.
    func pictureAttachment(_ inline: OpaqueInline) -> NSTextAttachment? {
        guard let ref = inline.image, let data = images[ref.relationshipId], let image = NSImage(data: data) else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: ref.size)
        return attachment
    }

    /// The bytes and file extension to store for an attachment's image.
    static func media(of attachment: NSTextAttachment) -> NewMedia? {
        let wrapper = attachment.fileWrapper
        let data = attachment.contents ?? (wrapper?.isRegularFile == true ? wrapper?.regularFileContents : nil)
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
