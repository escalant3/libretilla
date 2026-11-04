import Foundation

/// An open `.docx`: the lossless package plus the parsed main document body and styles.
public struct DocxDocument: Sendable {
    public var package: OPCPackage
    public let mainPartName: String
    public var body: DocumentBody
    public let styles: StyleSheet

    /// Why the document must open read-only, if it must.
    public var readOnlyReason: String? { body.readOnlyReason }
}

/// Cartilla's own OOXML codec (ADR 0002): reads and writes only what it understands and
/// copies everything else through byte for byte.
public struct OOXMLCodec: DocxCodec {
    static let stylesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let themeType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"

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
        // Styles only affect display; a damaged styles part shouldn't prevent opening.
        let styles = (try? StyleSheet(styles: part(Self.stylesType), theme: part(Self.themeType))) ?? StyleSheet()
        return DocxDocument(package: package, mainPartName: main, body: body, styles: styles)
    }

    public func write(_ document: DocxDocument) throws -> Data {
        if let reason = document.readOnlyReason { throw DocxCodecError.unsupported(reason) }
        var package = document.package
        package.setPart(document.mainPartName, data: document.body.serialized())
        return try package.serialized()
    }
}
