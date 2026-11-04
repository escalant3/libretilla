import AppKit

// Custom attributes the bridge puts on the text so a save can map it back to OOXML.
// Values are immutable reference objects compared by identity, so attribute runs never
// merge across two distinct source runs.

extension NSAttributedString.Key {
    /// `ParagraphOrigin` on every character of a paragraph, including its terminating `\n`.
    public static let cartillaParagraph = NSAttributedString.Key("cartilla.paragraph")
    /// `RunFormat` on the text of a run.
    public static let cartillaRun = NSAttributedString.Key("cartilla.run")
    /// `ParagraphFormat` on every character of a paragraph: what its `w:pPr` says. Replaced (never
    /// mutated) when the paragraph's formatting changes.
    public static let cartillaParagraphFormat = NSAttributedString.Key("cartilla.paragraphFormat")
    /// `OpaqueInlineBox` on the visible characters of an opaque inline (hyperlink text, object character, …).
    public static let cartillaOpaque = NSAttributedString.Key("cartilla.opaque")
    /// `MarkerBox` on the first character after invisible opaque inlines (bookmarks, comment ranges, …).
    public static let cartillaMarkers = NSAttributedString.Key("cartilla.markers")
    /// `OpaqueBlockBox` on the object character standing for a table, content control, ….
    public static let cartillaBlock = NSAttributedString.Key("cartilla.block")

    /// Attributes that must not be inherited by newly typed text (`NSTextView.typingAttributes`).
    public static let cartillaNonInheritable: [NSAttributedString.Key] = [
        .cartillaOpaque, .cartillaMarkers, .cartillaBlock, .attachment, .link,
    ]
}

/// Where a paragraph came from: its original parsed value (with source bytes) and the shape the
/// bridge gave it, used to tell whether it changed.
public final class ParagraphOrigin: NSObject, @unchecked Sendable {
    public let paragraph: Paragraph
    /// Hidden body-level items (bookmarks, comment ranges, …) that preceded this paragraph.
    public let leadingBlocks: [OpaqueBlock]
    /// Invisible inlines after the paragraph's last visible character.
    public let trailingMarkers: [OpaqueInline]
    /// The format the paragraph was shown with; any other `ParagraphFormat` means it was reformatted.
    public let format: ParagraphFormat
    let text: String
    let signature: [Span]

    init(
        paragraph: Paragraph, leadingBlocks: [OpaqueBlock], trailingMarkers: [OpaqueInline], format: ParagraphFormat,
        text: String, signature: [Span]
    ) {
        self.paragraph = paragraph
        self.leadingBlocks = leadingBlocks
        self.trailingMarkers = trailingMarkers
        self.format = format
        self.text = text
        self.signature = signature
    }
}

/// A run's direct formatting: parsed properties plus the exact `w:rPr` bytes they came from.
public final class RunFormat: NSObject, @unchecked Sendable {
    public let properties: RunProperties
    public let xml: Data?
    public init(properties: RunProperties, xml: Data?) {
        self.properties = properties
        self.xml = xml
    }

    /// A copy whose `fields` say what `new` says, rewriting only those children of the XML.
    public func setting(_ fields: Set<RunProperties.Field>, from new: RunProperties) -> RunFormat {
        var p = properties
        p.take(fields, from: new)
        guard p != properties else { return self }
        return RunFormat(properties: p, xml: p.patching(xml, fields: fields))
    }
}

/// A paragraph's direct formatting: parsed properties plus the exact `w:pPr` bytes (which may hold
/// a section break and things Cartilla doesn't model).
public final class ParagraphFormat: NSObject, @unchecked Sendable {
    public let properties: ParagraphProperties
    public let xml: Data?
    public init(properties: ParagraphProperties, xml: Data?) {
        self.properties = properties
        self.xml = xml
    }

    /// A copy whose `fields` say what `new` says, rewriting only those children of the XML.
    public func setting(_ fields: Set<ParagraphProperties.Field>, from new: ParagraphProperties) -> ParagraphFormat {
        var p = properties
        p.take(fields, from: new)
        guard p != properties else { return self }
        return ParagraphFormat(properties: p, xml: p.patching(xml, fields: fields))
    }

    /// The `w:pPr` without its section break (for the first pieces of a split paragraph).
    var xmlWithoutSectionBreak: Data? {
        guard properties.hasSectionBreak else { return xml }
        return ElementPatch.apply(
            [.remove("w:sectPr")], to: xml, wrapper: "w:pPr", order: ElementPatch.paragraphPropertiesOrder)
    }
}

public final class OpaqueInlineBox: NSObject, @unchecked Sendable {
    public let inline: OpaqueInline
    init(_ inline: OpaqueInline) { self.inline = inline }
}

public final class MarkerBox: NSObject, @unchecked Sendable {
    public let markers: [OpaqueInline]
    init(_ markers: [OpaqueInline]) { self.markers = markers }
}

public final class OpaqueBlockBox: NSObject, @unchecked Sendable {
    public let block: OpaqueBlock
    public let leadingBlocks: [OpaqueBlock]
    init(_ block: OpaqueBlock, leadingBlocks: [OpaqueBlock]) {
        self.block = block
        self.leadingBlocks = leadingBlocks
    }
}

/// Identity of the custom attributes over one attribute run; two paragraphs with equal text and
/// equal span lists are the same paragraph.
struct Span: Equatable {
    var length: Int
    var run: ObjectIdentifier?
    var opaque: ObjectIdentifier?
    var markers: ObjectIdentifier?

    static func signature(of text: NSAttributedString, in range: NSRange) -> [Span] {
        var spans: [Span] = []
        text.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            spans.append(
                Span(
                    length: r.length,
                    run: (attrs[.cartillaRun] as AnyObject?).map(ObjectIdentifier.init),
                    opaque: (attrs[.cartillaOpaque] as AnyObject?).map(ObjectIdentifier.init),
                    markers: (attrs[.cartillaMarkers] as AnyObject?).map(ObjectIdentifier.init)))
        }
        // enumerateAttributes splits on any attribute (fonts, colours…); merge spans with equal identities.
        var merged: [Span] = []
        for s in spans {
            if var last = merged.last, last.run == s.run, last.opaque == s.opaque, last.markers == s.markers {
                last.length += s.length
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }
}
