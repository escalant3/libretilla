import Foundation

/// The document's footnotes and endnotes (`word/footnotes.xml`, `word/endnotes.xml`), by `w:id`, read for printing
/// (backlog 24). Libretilla doesn't edit them: their parts are written back as they are.
public struct Notes: Sendable {
    public var footnotes: [String: HeadersFooters.Story] = [:]
    public var endnotes: [String: HeadersFooters.Story] = [:]

    public init() {}

    public func story(_ kind: OpaqueInline.NoteKind, id: String) -> HeadersFooters.Story? {
        kind == .footnote ? footnotes[id] : endnotes[id]
    }
}

extension OpaqueInline {
    /// A footnote or endnote reference's `w:id`.
    public var noteId: String? {
        guard noteReference != nil, let root = (try? RawXML.Document(data: xml, part: kind))?.root,
            let reference =
                (root.descendants(named: "w:footnoteReference") + root.descendants(named: "w:endnoteReference")).first
        else { return nil }
        return reference.attribute("w:id")
    }
}

extension OOXMLCodec {
    static let footnotesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"
    static let endnotesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"

    /// Each note's paragraphs, parsed like a header's (separators and continuation notices left out).
    static func readNotes(package: OPCPackage, rels: [Relationship]) -> Notes {
        var notes = Notes()
        for (type, element) in [(footnotesType, "w:footnote"), (endnotesType, "w:endnote")] {
            guard let name = rels.first(where: { $0.type == type && !$0.isExternal })?.resolvedPartName,
                let data = package[name], let doc = try? RawXML.Document(data: Data([UInt8](data)), part: name)
            else { continue }
            // The root's namespace declarations, for each note parsed on its own.
            let declarations = doc.root.attributes.filter { $0.name.hasPrefix("xmlns") }.map {
                " \($0.name)=\"\(RawXML.escapeAttribute($0.value))\""
            }.joined()
            for note in doc.root.childElements(named: element) {
                guard let id = note.attribute("w:id"), (note.attribute("w:type") ?? "normal") == "normal",
                    !note.endTagRange.isEmpty
                else { continue }
                var xml = Data("<w:ftr\(declarations)>".utf8)
                xml.append(doc.slice(note.startTagRange.upperBound..<note.endTagRange.lowerBound))
                xml.append(Data("</w:ftr>".utf8))
                guard let body = try? DocumentBody(data: xml, part: name), body.readOnlyReason == nil else { continue }
                let story = HeadersFooters.Story(partName: nil, body: body)
                if element == "w:footnote" { notes.footnotes[id] = story } else { notes.endnotes[id] = story }
            }
        }
        return notes
    }
}
