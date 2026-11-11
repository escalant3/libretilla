import AppKit

/// Colours chosen for a white page, as shown on a dark one (Dark Mode). Display only: the document's colours are
/// untouched, and print is always on white paper.
public enum ReadableColor {
    /// The colour to draw `color` (nil: Word's automatic colour) in on a dark page, or nil to draw it as it is.
    /// Dark colours are drawn lighter; text on a highlight or a light cell fill is drawn dark.
    public static func onDarkPage(_ color: NSColor?, onHighlight: Bool) -> NSColor? {
        // Highlights keep their light colours, so the text on them is drawn dark, as in Word's Dark Mode.
        if onHighlight {
            guard let rgb = color?.usingColorSpace(.sRGB), color?.type != .catalog else { return .black }
            return luminance(rgb) > 0.4 ? .black : nil
        }
        // Automatic colour (a system colour) already adapts.
        guard let color, color.type != .catalog, let rgb = color.usingColorSpace(.sRGB) else { return nil }
        // 4.5:1 against the dark page (luminance ≈ 0.015) needs a luminance of about 0.25.
        let wanted: CGFloat = 0.25
        guard luminance(rgb) < wanted else { return nil }
        if rgb.saturationComponent < 0.15 { return .textColor }
        var t: CGFloat = 0.1
        while t < 1 {
            if let mixed = rgb.blended(withFraction: t, of: .white), luminance(mixed) >= wanted { return mixed }
            t += 0.1
        }
        return .textColor
    }

    /// WCAG relative luminance of an sRGB colour.
    public static func luminance(_ c: NSColor) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    /// Whether drawing is happening in Dark Mode (the current drawing appearance).
    public static var isDrawingDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
