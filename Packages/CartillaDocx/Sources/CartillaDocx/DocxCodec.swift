import Foundation

/// The app depends on this protocol, never on a concrete DOCX library
/// (bootstrap §5.2, ADR 0002).
public protocol DocxCodec: Sendable {
    func read(_ url: URL) throws -> DocxDocument
    func write(_ document: DocxDocument, to url: URL) throws
}

public enum DocxCodecError: Error, Equatable, Sendable {
    case notAZipArchive
    case missingPart(String)
    case malformedXML(part: String, reason: String)
    case unsupported(String)
}
