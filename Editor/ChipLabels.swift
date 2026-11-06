import Foundation
import LibretillaDocx

/// Spanish (and any other) names for the placeholder chips LibretillaDocx draws for content the editor can't show
/// yet. The package names them in English; `install()` hands it this translation.
enum ChipLabels {
    static func install() {
        AttributedStringBridge.localizeLabel = localized
    }

    static func localized(_ english: String) -> String {
        switch english {
        case "Text box": String(localized: "Text box", comment: "Placeholder for a text box in the document")
        case "Image": String(localized: "Image", comment: "Placeholder for a picture Libretilla can't show")
        case "Object": String(localized: "Object", comment: "Placeholder for an embedded object")
        case "Equation": String(localized: "Equation", comment: "Placeholder for an equation")
        case "Footnote": String(localized: "Footnote", comment: "Placeholder for a footnote reference")
        case "Endnote": String(localized: "Endnote", comment: "Placeholder for an endnote reference")
        case "Comment": String(localized: "Comment", comment: "Placeholder for a comment reference")
        case "Symbol": String(localized: "Symbol", comment: "Placeholder for a symbol character")
        case "Page break": String(localized: "Page break", comment: "Chip shown for a page break")
        case "Column break": String(localized: "Column break", comment: "Chip shown for a column break")
        case "Content control": String(localized: "Content control", comment: "Placeholder for a Word content control")
        case "Section": String(localized: "Section", comment: "Placeholder for a section break")
        case "Page number":
            String(localized: "Page number", comment: "Chip for a page number field in a header or footer")
        case "Page count":
            String(localized: "Page count", comment: "Chip for a page count field in a header or footer")
        default: table(english) ?? english
        }
    }

    /// "Table, 3 × 4" (rows × columns).
    private static func table(_ english: String) -> String? {
        let parts = english.split(separator: " ")
        guard parts.count == 4, parts[0] == "Table,", parts[2] == "×", let rows = Int(parts[1]),
            let columns = Int(parts[3])
        else { return nil }
        return String(localized: "Table, \(rows) × \(columns)", comment: "Placeholder for a table: rows × columns")
    }
}
