import AppKit

/// App-wide choices, kept in `UserDefaults` and shown in Settings (⌘,). Windows apply them as they change.
enum Preferences {
    static let keepsPageLightKey = "LibretillaKeepsPageLight"
    static let rulerUnitsKey = "LibretillaRulerUnits"
    static let outlineShownKey = "LibretillaOutlineShown"

    /// The ruler's units, by `NSRulerView`'s built-in names.
    enum RulerUnit: String, CaseIterable, Identifiable {
        case centimeters = "Centimeters"
        case inches = "Inches"
        case points = "Points"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .centimeters: String(localized: "Centimeters")
            case .inches: String(localized: "Inches")
            case .points: String(localized: "Points")
            }
        }

        var measurementUnit: NSRulerView.UnitName { .init(rawValue) }

        /// Inches where the locale measures in inches (the US), centimetres elsewhere.
        static var localeDefault: RulerUnit {
            Locale.current.measurementSystem == .us ? .inches : .centimeters
        }
    }

    static var rulerUnit: RulerUnit {
        UserDefaults.standard.string(forKey: rulerUnitsKey).flatMap(RulerUnit.init(rawValue:)) ?? .localeDefault
    }

    /// A white page with dark text in Dark Mode, as printed (off: the page follows the appearance).
    static var keepsPageLight: Bool { UserDefaults.standard.bool(forKey: keepsPageLightKey) }
}
