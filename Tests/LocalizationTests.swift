import Foundation
import XCTest

@testable import Cartilla

/// Bootstrap §10 M4: "strings fully localized". Every string the app's code localizes has a Spanish translation.
final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testEveryLocalizedStringHasSpanish() throws {
        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("Resources/Localizable.xcstrings")))
        let strings = try XCTUnwrap((catalog as? [String: Any])?["strings"] as? [String: [String: Any]])
        let literal = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:[^"\\]|\\.)*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var checked = 0
        for folder in ["App", "Document", "Editor", "UI"] {
            let dir = Self.root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                let all = NSRange(source.startIndex..., in: source)
                for match in literal.matches(in: source, range: all) {
                    let raw = String(source[Range(match.range(at: 1), in: source)!])
                    // Interpolations become %@ or %lld in the catalog, depending on their type.
                    let pattern = interpolation.stringByReplacingMatches(
                        in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "\u{1}")
                    let key = strings.keys.first { candidate in
                        candidate == pattern
                            || candidate.replacingOccurrences(of: "%lld", with: "\u{1}")
                                .replacingOccurrences(of: "%@", with: "\u{1}") == pattern
                    }
                    guard let key else {
                        XCTFail("\(file): \"\(raw)\" is missing from Localizable.xcstrings")
                        continue
                    }
                    let es = (strings[key]?["localizations"] as? [String: Any])?["es"]
                    XCTAssertNotNil(es, "\(file): \"\(key)\" has no Spanish translation")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 150)
    }

    func testTheAppShipsItsSpanishStrings() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj"))
        let spanish = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(spanish.localizedString(forKey: "Settings…", value: nil, table: nil), "Ajustes…")
        XCTAssertEqual(spanish.localizedString(forKey: "Show Outline", value: nil, table: nil), "Mostrar esquema")
    }

    func testChipLabelsAreTranslated() {
        XCTAssertEqual(ChipLabels.localized("Unknown thing"), "Unknown thing")
        // In the test run's language (English) the labels come back as they are, tables included.
        XCTAssertEqual(ChipLabels.localized("Table, 3 × 4"), String(localized: "Table, \(3) × \(4)"))
        XCTAssertEqual(ChipLabels.localized("Footnote"), String(localized: "Footnote"))
    }
}
