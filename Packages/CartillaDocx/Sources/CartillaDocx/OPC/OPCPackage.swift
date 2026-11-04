import Foundation
import ZIPFoundation

/// An Open Packaging Conventions package (the zip inside a `.docx`), kept lossless:
/// every part's bytes, the original entry order and modification dates are retained, so
/// parts Cartilla doesn't modify are written back byte for byte (ADR 0002).
public struct OPCPackage: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var name: String
        public var data: Data
        public var modificationDate: Date
    }

    /// Parts in their original zip order.
    public private(set) var parts: [Part]
    /// The exact bytes this package was read from, if it hasn't been modified since.
    private var pristineData: Data?

    public init(parts: [Part]) {
        self.parts = parts
        self.pristineData = nil
    }

    public init(data: Data) throws {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocxCodecError.notAZipArchive
        }
        var parts: [Part] = []
        for entry in archive where entry.type == .file {
            var bytes = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: false) { bytes.append($0) }
            } catch {
                throw DocxCodecError.corruptArchive(entry.path)
            }
            let date = entry.fileAttributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 315_532_800)
            parts.append(Part(name: entry.path, data: bytes, modificationDate: date))
        }
        self.parts = parts
        self.pristineData = data
    }

    public var partNames: [String] { parts.map(\.name) }

    public subscript(name: String) -> Data? {
        parts.first { $0.name == name }?.data
    }

    /// Replaces (or adds) a part. Replacing a part with identical bytes is a no-op, so an
    /// unedited document still writes back its original file exactly.
    public mutating func setPart(_ name: String, data: Data) {
        if let i = parts.firstIndex(where: { $0.name == name }) {
            guard parts[i].data != data else { return }
            parts[i].data = data
            parts[i].modificationDate = Date()
        } else {
            parts.append(Part(name: name, data: data, modificationDate: Date()))
        }
        pristineData = nil
    }

    /// Serializes the package. Returns the original bytes untouched when nothing changed.
    public func serialized() throws -> Data {
        if let pristineData { return pristineData }
        let archive = try Archive(accessMode: .create)
        for part in parts {
            let data = part.data
            try archive.addEntry(
                with: part.name, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: part.modificationDate, compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        guard let out = archive.data else { throw DocxCodecError.unsupported("could not create zip archive") }
        return out
    }

    // MARK: - Relationships

    /// Relationships declared by `part` (`""` for the package root), from its `_rels/*.rels` part.
    public func relationships(of part: String) throws -> [Relationship] {
        let relsName = Self.relsPartName(for: part)
        guard let data = self[relsName] else { return [] }
        let root = try RawXML.Document(data: data, part: relsName).root
        let base = part.split(separator: "/").dropLast().joined(separator: "/")
        return root.childElements(named: "Relationship").map { e in
            let target = e.attribute("Target") ?? ""
            let external = e.attribute("TargetMode") == "External"
            return Relationship(
                id: e.attribute("Id") ?? "", type: e.attribute("Type") ?? "", target: target,
                isExternal: external,
                resolvedPartName: external ? nil : Self.resolve(target, against: base))
        }
    }

    /// The main document part (`word/document.xml` in practice), found through the package relationships.
    public func mainDocumentPartName() throws -> String {
        let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        let strictOfficeDocument = "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"
        guard
            let rel = try relationships(of: "").first(where: {
                $0.type == officeDocument || $0.type == strictOfficeDocument
            }),
            let name = rel.resolvedPartName, self[name] != nil
        else { throw DocxCodecError.missingPart("main document") }
        return name
    }

    /// Writes the part that `owner` relates to with `type`. If there's none yet, creates it next to
    /// `owner` as `defaultName`, with a relationship and a content-type override (spliced in, so
    /// the existing relationships and types keep their bytes).
    public mutating func setRelatedPart(
        of owner: String, type: String, contentType: String, defaultName: String, data: Data
    ) throws {
        if let existing = try relationships(of: owner).first(where: { $0.type == type })?.resolvedPartName,
            self[existing] != nil
        {
            setPart(existing, data: data)
            return
        }
        let folder = owner.split(separator: "/").dropLast().joined(separator: "/")
        var name = folder.isEmpty ? defaultName : folder + "/" + defaultName
        var n = 1
        while self[name] != nil {
            n += 1
            let stem = (defaultName as NSString).deletingPathExtension
            let ext = (defaultName as NSString).pathExtension
            name = (folder.isEmpty ? "" : folder + "/") + "\(stem)\(n).\(ext)"
        }
        let target = String(name.dropFirst(folder.isEmpty ? 0 : folder.count + 1))

        // Relationship.
        let relsName = Self.relsPartName(for: owner)
        let existingIds = Set(try relationships(of: owner).map(\.id))
        var k = existingIds.count + 1
        while existingIds.contains("rId\(k)") { k += 1 }
        let rel =
            "<Relationship Id=\"rId\(k)\" Type=\"\(RawXML.escapeAttribute(type))\" "
            + "Target=\"\(RawXML.escapeAttribute(target))\"/>"
        let rels =
            self[relsName]
            ?? Data(
                ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
                    + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + "</Relationships>").utf8)
        setPart(relsName, data: try Self.appending(rel, toRootOf: rels, part: relsName))

        // Content type.
        let typesName = "[Content_Types].xml"
        guard let types = self[typesName] else { throw DocxCodecError.missingPart(typesName) }
        let override =
            "<Override PartName=\"/\(RawXML.escapeAttribute(name))\" ContentType=\"\(RawXML.escapeAttribute(contentType))\"/>"
        setPart(typesName, data: try Self.appending(override, toRootOf: types, part: typesName))

        setPart(name, data: data)
    }

    /// Adds a relationship from `owner` (spliced into its `.rels`, so existing ones keep their bytes) and
    /// returns its new id.
    public mutating func addRelationship(of owner: String, type: String, target: String, external: Bool) throws
        -> String
    {
        let relsName = Self.relsPartName(for: owner)
        let existingIds = Set(try relationships(of: owner).map(\.id))
        var k = existingIds.count + 1
        while existingIds.contains("rId\(k)") { k += 1 }
        let rel =
            "<Relationship Id=\"rId\(k)\" Type=\"\(RawXML.escapeAttribute(type))\" "
            + "Target=\"\(RawXML.escapeAttribute(target))\"" + (external ? " TargetMode=\"External\"/>" : "/>")
        let rels =
            self[relsName]
            ?? Data(
                ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
                    + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + "</Relationships>").utf8)
        setPart(relsName, data: try Self.appending(rel, toRootOf: rels, part: relsName))
        return "rId\(k)"
    }

    /// Inserts `element` just before the root's end tag.
    static func appending(_ element: String, toRootOf xml: Data, part: String) throws -> Data {
        var bytes = Data([UInt8](xml))
        let root = try RawXML.Document(data: bytes, part: part).root
        if root.endTagRange.isEmpty {
            // Self-closing root: `<Types …/>` → `<Types …>element</Types>`.
            var open = Data([UInt8](bytes[root.startTagRange]))
            while let last = open.last, last == UInt8(ascii: ">") || last == UInt8(ascii: "/") || last == 0x20 {
                open.removeLast()
            }
            bytes.replaceSubrange(root.range, with: open + Data(">\(element)</\(root.name)>".utf8))
            return bytes
        }
        bytes.insert(contentsOf: Data(element.utf8), at: root.endTagRange.lowerBound)
        return bytes
    }

    static func relsPartName(for part: String) -> String {
        guard !part.isEmpty else { return "_rels/.rels" }
        var components = part.split(separator: "/").map(String.init)
        let file = components.removeLast()
        return (components + ["_rels", file + ".rels"]).joined(separator: "/")
    }

    /// Joins a relative OPC target onto a base folder, collapsing `.` and `..`.
    static func resolve(_ target: String, against base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var out: [Substring] = base.split(separator: "/")
        for c in target.split(separator: "/") {
            switch c {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(c)
            }
        }
        return out.joined(separator: "/")
    }
}

public struct Relationship: Sendable, Equatable {
    public var id: String
    public var type: String
    public var target: String
    public var isExternal: Bool
    /// Package part name for internal targets, e.g. `word/styles.xml`.
    public var resolvedPartName: String?
}
