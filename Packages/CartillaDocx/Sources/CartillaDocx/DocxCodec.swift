import Foundation

/// The app depends on this protocol, never on a concrete implementation (bootstrap §5.2, ADR 0002).
public protocol DocxCodec: Sendable {
    func read(_ data: Data) throws -> DocxDocument
    func write(_ document: DocxDocument) throws -> Data
}

public enum DocxCodecError: Error, Equatable, Sendable {
    case notAZipArchive
    case corruptArchive(String)
    case missingPart(String)
    case malformedXML(part: String, reason: String)
    case unsupported(String)
}

extension DocxCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZipArchive: "The file isn't a valid Word document (it isn't a zip package)."
        case .corruptArchive(let p): "The Word document is damaged (part \(p) couldn't be read)."
        case .missingPart(let p): "The Word document is incomplete (missing \(p))."
        case .malformedXML(let part, let reason): "The Word document is damaged (\(part): \(reason))."
        case .unsupported(let what): "This Word document uses something Cartilla doesn't support yet: \(what)."
        }
    }
}
