import Foundation

/// A `w:hyperlink` holding only plain runs (ECMA-376 Part 1, §17.16.22). Hyperlinks with anything else
/// inside (fields, bookmarks, tracked changes, …) stay opaque.
///
/// External links point at a relationship (`r:id`) of the main part; internal ones at a bookmark
/// (`w:anchor`). A new or retargeted link carries `newTarget`; the codec turns it into a relationship
/// when writing.
public struct Hyperlink: Sendable {
    /// Start-tag attributes other than `r:id` (`w:anchor`, `w:history`, `w:tooltip`, …), in source order.
    public var attributes: [RawXML.Attribute]
    public var relationshipId: String?
    /// The URL a new or retargeted link points to; replaced by a relationship on write.
    public var newTarget: String?
    public var runs: [Run]
    /// Exact source bytes. While set, `serialized()` returns them verbatim.
    public var original: Data?

    public var anchor: String? { attributes.first { $0.name == "w:anchor" }?.value }
    public var text: String { runs.map(\.text).joined() }

    /// A new external link, as Word writes one.
    public init(target: String, runs: [Run]) {
        attributes = [RawXML.Attribute(name: "w:history", value: "1")]
        relationshipId = nil
        newTarget = target
        self.runs = runs
        original = nil
    }

    init?(parsing e: RawXML.Element, in doc: RawXML.Document) {
        guard e.name == "w:hyperlink" else { return nil }
        var runs: [Run] = []
        for node in e.children {
            switch node {
            case .text(let t) where t.isWhitespace: continue
            case .element(let r) where r.name == "w:r":
                guard let run = Run(parsing: r, in: doc) else { return nil }
                runs.append(run)
            default: return nil
            }
        }
        guard !runs.isEmpty, e.attribute("r:id") != nil || e.attribute("w:anchor") != nil else { return nil }
        relationshipId = e.attribute("r:id")
        attributes = e.attributes.filter { $0.name != "r:id" }
        newTarget = nil
        self.runs = runs
        original = doc.slice(e.range)
    }

    /// This link pointing at `url` (a new relationship is made on write).
    public func retargeted(to url: String) -> Hyperlink {
        var link = self
        link.relationshipId = nil
        link.newTarget = url
        link.attributes.removeAll { $0.name == "w:anchor" }
        link.original = nil
        return link
    }

    /// This link with `runs` as its content; keeps the source bytes if nothing changed.
    func with(runs new: [Run]) -> Hyperlink {
        var link = self
        let same =
            new.count == runs.count
            && zip(new, runs).allSatisfy {
                $0.text == $1.text && $0.propertiesXML == $1.propertiesXML && $0.properties == $1.properties
            }
        if !same {
            link.runs = new
            link.original = nil
        }
        return link
    }

    public func serialized() -> Data {
        if let original { return original }
        var tag = "<w:hyperlink"
        if let relationshipId { tag += " r:id=\"\(RawXML.escapeAttribute(relationshipId))\"" }
        for a in attributes { tag += " \(a.name)=\"\(RawXML.escapeAttribute(a.value))\"" }
        var out = Data((tag + ">").utf8)
        for run in runs { out.append(run.serialized()) }
        out.append(Data("</w:hyperlink>".utf8))
        return out
    }
}

// MARK: - Writing new links

extension OOXMLCodec {
    static let hyperlinkType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// Gives every new or retargeted link a relationship, reusing one with the same target (so repeated
    /// autosaves of the same edit don't add more).
    static func resolveNewHyperlinks(in body: inout DocumentBody, package: inout OPCPackage, part: String) throws {
        var byTarget: [String: String] = [:]
        var loaded = false
        for (b, block) in body.blocks.enumerated() {
            guard case .paragraph(var p) = block else { continue }
            var changed = false
            for (i, inline) in p.inlines.enumerated() {
                guard case .hyperlink(var link) = inline, let target = link.newTarget else { continue }
                if !loaded {
                    for rel in try package.relationships(of: part) where rel.type == hyperlinkType && rel.isExternal {
                        byTarget[rel.target] = byTarget[rel.target] ?? rel.id
                    }
                    loaded = true
                }
                let id: String
                if let existing = byTarget[target] {
                    id = existing
                } else {
                    id = try package.addRelationship(of: part, type: hyperlinkType, target: target, external: true)
                    byTarget[target] = id
                }
                link.relationshipId = id
                link.newTarget = nil
                p.inlines[i] = .hyperlink(link)
                changed = true
            }
            if changed { body.blocks[b] = .paragraph(p) }
        }
        if loaded { body.declareNamespace("r", relationshipsNamespace) }
    }
}

extension DocumentBody {
    /// Adds `xmlns:name="uri"` to the root element unless its start tag already declares that prefix.
    mutating func declareNamespace(_ name: String, _ uri: String) {
        let bytes = [UInt8](self.prefix)
        // The root start tag is the first "<" not followed by "?" or "!"; insert before its ">".
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count, bytes[i + 1] != UInt8(ascii: "?"),
                bytes[i + 1] != UInt8(ascii: "!")
            {
                break
            }
            i += 1
        }
        guard let close = bytes[i...].firstIndex(of: UInt8(ascii: ">")) else { return }
        if String(decoding: bytes[i...close], as: UTF8.self).contains("xmlns:\(name)=") { return }
        var out = self.prefix
        out.insert(contentsOf: Data(" xmlns:\(name)=\"\(RawXML.escapeAttribute(uri))\"".utf8), at: close)
        self.prefix = out
    }
}
