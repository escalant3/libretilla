import AppKit
import LibretillaDocx

/// A heading in the document: a paragraph whose Word style is Title or Heading 1–9. Shared by the outline
/// sidebar and VoiceOver's heading rotor.
struct OutlineHeading: Equatable {
    /// 0 for Title, 1–9 for Heading 1–9.
    let level: Int
    let title: String
    /// The paragraph's text, without its newline.
    let range: NSRange
}

enum DocumentOutline {
    /// The headings of `text`, top to bottom. Empty headings are left out.
    static func headings(in text: NSAttributedString, styles: StyleSheet) -> [OutlineHeading] {
        let string = text.string as NSString
        var out: [OutlineHeading] = []
        var levels: [String: Int?] = [:]
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraph) }
            let format = text.attribute(.libretillaParagraphFormat, at: paragraph.location, effectiveRange: nil)
            let styleId = (format as? ParagraphFormat)?.properties.styleId ?? ""
            let level: Int?
            if let known = levels[styleId] {
                level = known
            } else {
                level = styles.outlineLevel(ofParagraphStyle: styleId.isEmpty ? nil : styleId)
                levels[styleId] = level
            }
            guard let level else { continue }
            var body = paragraph
            while body.length > 0, Self.isLineEnd(string.character(at: NSMaxRange(body) - 1)) { body.length -= 1 }
            let title = Self.displayTitle(string.substring(with: body))
            guard !title.isEmpty else { continue }
            out.append(OutlineHeading(level: level, title: title, range: body))
        }
        return out
    }

    /// The heading the character at `location` falls under (the last one starting at or before it).
    static func index(of location: Int, in headings: [OutlineHeading]) -> Int? {
        headings.lastIndex { $0.range.location <= location }
    }

    private static func isLineEnd(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2029 || c == 0x2028 }

    /// Object characters (pictures, chips) and runs of whitespace don't belong in a heading's title.
    static func displayTitle(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\u{FFFC}", "\u{200B}", "\u{000C}": ""
            case "\t", "\u{2028}", "\u{00A0}": " "
            default: String(scalar)
            }
        }.joined()
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
