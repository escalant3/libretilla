import Foundation

/// An open `.docx`: the lossless package plus the parsed main document body, styles and lists.
public struct DocxDocument: Sendable {
    public var package: OPCPackage
    public let mainPartName: String
    public var body: DocumentBody
    /// Edited through `StyleSheet`'s splicing methods; written back only if its bytes changed.
    public var styles: StyleSheet
    /// Edited through `Numbering.addList`; written back only if its bytes changed.
    public var numbering: Numbering
    /// External link targets of the main part, by relationship id (as read).
    public var hyperlinkTargets: [String: String] = [:]
    /// Image bytes the main part embeds, by relationship id (as read).
    public var images: [String: Data] = [:]

    /// Why the document must open read-only, if it must.
    public var readOnlyReason: String? { body.readOnlyReason }
}

/// Cartilla's own OOXML codec (ADR 0002): reads and writes only what it understands and
/// copies everything else through byte for byte.
public struct OOXMLCodec: DocxCodec {
    static let stylesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let themeType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    static let numberingType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let stylesContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"
    static let numberingContentType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"

    public init() {}

    public func read(_ data: Data) throws -> DocxDocument {
        let package = try OPCPackage(data: data)
        let main = try package.mainDocumentPartName()
        guard let documentXML = package[main] else { throw DocxCodecError.missingPart(main) }
        let body = try DocumentBody(data: documentXML, part: main)
        let rels = (try? package.relationships(of: main)) ?? []
        func part(_ type: String) -> Data? {
            rels.first { $0.type == type }?.resolvedPartName.flatMap { package[$0] }
        }
        // Styles and lists only affect display; a damaged part shouldn't prevent opening. A part
        // that can't be parsed is never rewritten either (its sheet has no source bytes).
        let styles = (try? StyleSheet(styles: part(Self.stylesType), theme: part(Self.themeType))) ?? StyleSheet()
        let numbering = (try? Numbering(xml: part(Self.numberingType))) ?? Numbering()
        var doc = DocxDocument(package: package, mainPartName: main, body: body, styles: styles, numbering: numbering)
        doc.hyperlinkTargets = Dictionary(
            rels.filter { $0.type == Self.hyperlinkType && $0.isExternal }.map { ($0.id, $0.target) },
            uniquingKeysWith: { a, _ in a })
        for rel in rels where rel.type == Self.imageType && !rel.isExternal {
            if let name = rel.resolvedPartName, let data = package[name] { doc.images[rel.id] = data }
        }
        return doc
    }

    public func write(_ document: DocxDocument) throws -> Data {
        if let reason = document.readOnlyReason { throw DocxCodecError.unsupported(reason) }
        var package = document.package
        var body = document.body
        try Self.resolveNewHyperlinks(in: &body, package: &package, part: document.mainPartName)
        try Self.resolveNewPictures(in: &body, package: &package, part: document.mainPartName)
        package.setPart(document.mainPartName, data: body.serialized())
        if let xml = document.styles.stylesXML {
            try package.setRelatedPart(
                of: document.mainPartName, type: Self.stylesType, contentType: Self.stylesContentType,
                defaultName: "styles.xml", data: xml)
        }
        if let xml = document.numbering.xml {
            try package.setRelatedPart(
                of: document.mainPartName, type: Self.numberingType, contentType: Self.numberingContentType,
                defaultName: "numbering.xml", data: xml)
        }
        return try package.serialized()
    }
}
