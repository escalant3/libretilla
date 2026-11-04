import AppKit
import CartillaDocx  // DocxCodec + DocxDocument (M1)

/// The `.docx` document. M0 stub: lifecycle only — reading/writing arrives in M1
/// once ADR 0002 (DOCX library) is accepted.
final class CartillaDocument: NSDocument {
    static let docxType = "org.openxmlformats.wordprocessingml.document"

    /// The `.docx` on disk *is* the document (bootstrap §5.4).
    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // TODO(M1): decode via a `DocxCodec` into a `DocxDocument`.
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError)
    }

    override func data(ofType typeName: String) throws -> Data {
        // TODO(M1): encode an immutable snapshot of the model.
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnsupportedSchemeError)
    }
}
