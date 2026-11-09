import AppKit
import LibretillaDocx
import SwiftUI

/// Format ▸ Picture…: a sheet for a picture's size, rotation, brightness, contrast and opacity, all of which a
/// .docx stores (`PictureFormat`). Changes show in the document as they're made (`onChange`); `onDone` gets
/// the final format, or nil on Cancel.
@MainActor @Observable
final class PictureFormatSheet {
    private(set) var format: PictureFormat
    var keepAspectRatio = true
    @ObservationIgnored private let original: PictureFormat
    @ObservationIgnored private let naturalSize: CGSize
    /// Points per unit shown (Settings ▸ Ruler units).
    @ObservationIgnored let unit: (points: CGFloat, symbol: String, digits: Int)
    @ObservationIgnored var onChange: ((PictureFormat) -> Void)?
    @ObservationIgnored var onDone: ((PictureFormat?) -> Void)?
    @ObservationIgnored private(set) var window: NSWindow?

    /// Word's limits for a picture's width and height.
    static let maximumSide: CGFloat = 1584
    static let minimumSide: CGFloat = 1

    init(format: PictureFormat, naturalSize: CGSize, unit: Preferences.RulerUnit = Preferences.rulerUnit) {
        self.format = format
        original = format
        self.naturalSize = naturalSize
        self.unit = unit.display
    }

    /// Shows the sheet on `parent`; `onEnd` runs once it has gone.
    func present(on parent: NSWindow, onEnd: @escaping @MainActor () -> Void) {
        window = Sheet.present(
            String(localized: "Format Picture"), on: parent, content: PictureFormatView(sheet: self), onEnd: onEnd)
    }

    private func update(_ change: (inout PictureFormat) -> Void) {
        var new = format
        change(&new)
        guard new != format else { return }
        format = new
        onChange?(format)
    }

    // MARK: Values as the fields and sliders show them

    var width: Double {
        get { Double(format.size.width / unit.points) }
        set { setWidth(CGFloat(newValue) * unit.points) }
    }
    var height: Double {
        get { Double(format.size.height / unit.points) }
        set { setHeight(CGFloat(newValue) * unit.points) }
    }
    /// −180…180, as the slider shows it.
    var rotation: Double {
        get { Double(format.rotation > 180 ? format.rotation - 360 : format.rotation) }
        set { update { $0.rotation = PictureFormat.normalized(CGFloat(newValue.rounded())) } }
    }
    /// Percentages.
    var brightness: Double {
        get { Double(format.brightness * 100) }
        set { update { $0.brightness = min(max(CGFloat(newValue.rounded()) / 100, -1), 1) } }
    }
    var contrast: Double {
        get { Double(format.contrast * 100) }
        set { update { $0.contrast = min(max(CGFloat(newValue.rounded()) / 100, -1), 1) } }
    }
    var opacity: Double {
        get { Double(format.opacity * 100) }
        set { update { $0.opacity = min(max(CGFloat(newValue.rounded()) / 100, 0), 1) } }
    }

    // MARK: Changes

    private static func clampedSide(_ v: CGFloat) -> CGFloat { min(max(v, minimumSide), maximumSide) }

    /// Sets the width (points), and the height with it when the aspect ratio is kept.
    func setWidth(_ width: CGFloat) {
        update { f in
            let w = Self.clampedSide(width)
            if keepAspectRatio, f.size.width > 0 {
                f.size = CGSize(width: w, height: Self.clampedSide((f.size.height * w / f.size.width).rounded()))
            } else {
                f.size.width = w
            }
        }
    }

    /// Sets the height (points), and the width with it when the aspect ratio is kept.
    func setHeight(_ height: CGFloat) {
        update { f in
            let h = Self.clampedSide(height)
            if keepAspectRatio, f.size.height > 0 {
                f.size = CGSize(width: Self.clampedSide((f.size.width * h / f.size.height).rounded()), height: h)
            } else {
                f.size.height = h
            }
        }
    }

    /// Turns the picture a quarter turn, as Word's Rotate Left 90° and Rotate Right 90°.
    func rotate(by degrees: CGFloat) {
        update { f in
            // Snap to the next quarter turn, so a picture at 30° turns to 0° or 90°, not 120°.
            let quarters =
                degrees > 0 ? (f.rotation / 90 + 0.001).rounded(.up) : (f.rotation / 90 - 0.001).rounded(.down)
            f.rotation = PictureFormat.normalized(quarters * 90)
        }
    }

    /// The image's own size, scaled down (keeping its proportions) if it's bigger than Word allows.
    var originalPictureSize: CGSize {
        let w = max(naturalSize.width, Self.minimumSide)
        let h = max(naturalSize.height, Self.minimumSide)
        let scale = min(1, Self.maximumSide / max(w, h))
        return CGSize(width: Self.clampedSide((w * scale).rounded()), height: Self.clampedSide((h * scale).rounded()))
    }

    func originalSize() { update { $0.size = originalPictureSize } }

    func reset() { update { $0 = PictureFormat(size: originalPictureSize) } }

    // MARK: Closing

    private func close(with result: PictureFormat?) {
        let done = onDone
        onDone = nil
        done?(result)
        Sheet.end(window)
    }

    func ok() {
        // Commit a field still being typed in.
        window?.makeFirstResponder(nil)
        close(with: format == original ? nil : format)
    }

    func cancel() { close(with: nil) }
}

private struct PictureFormatView: View {
    @Bindable var sheet: PictureFormatSheet

    var body: some View {
        let side =
            Double(
                PictureFormatSheet.minimumSide / sheet.unit.points)...Double(
                PictureFormatSheet.maximumSide / sheet.unit.points)
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text(String(localized: "Width:")).gridColumnAlignment(.trailing)
                    number(String(localized: "Width"), $sheet.width, sheet.unit.symbol, side, digits: sheet.unit.digits)
                }
                GridRow {
                    Text(String(localized: "Height:"))
                    number(
                        String(localized: "Height"), $sheet.height, sheet.unit.symbol, side, digits: sheet.unit.digits)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack {
                        Toggle(String(localized: "Keep aspect ratio"), isOn: $sheet.keepAspectRatio)
                        Button(String(localized: "Original Size"), action: sheet.originalSize)
                    }
                }
                GridRow {
                    Text(String(localized: "Rotation:"))
                    HStack {
                        slider(String(localized: "Rotation"), $sheet.rotation, -180...180)
                        number(String(localized: "Rotation"), $sheet.rotation, "°", -360...360)
                        rotateButton(String(localized: "Rotate Left"), "rotate.left", by: -90)
                        rotateButton(String(localized: "Rotate Right"), "rotate.right", by: 90)
                    }
                }
                .padding(.top, 8)
                adjustment(String(localized: "Brightness:"), String(localized: "Brightness"), $sheet.brightness)
                adjustment(String(localized: "Contrast:"), String(localized: "Contrast"), $sheet.contrast)
                adjustment(String(localized: "Opacity:"), String(localized: "Opacity"), $sheet.opacity, 0...100)
            }
            SheetButtons(cancel: sheet.cancel, confirmTitle: String(localized: "OK"), confirm: sheet.ok) {
                Button(String(localized: "Reset"), action: sheet.reset)
                    .help(String(localized: "Back to the picture's own size, unturned and unadjusted"))
            }
        }
        .padding(20)
        .fixedSize()
    }

    private func number(
        _ label: String, _ value: Binding<Double>, _ suffix: String, _ range: ClosedRange<Double>, digits: Int = 0
    ) -> some View {
        HStack(spacing: 6) {
            NumberField(label: label, value: value, digits: digits, range: range)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        Slider(value: value, in: range) { Text(label) }.labelsHidden().frame(width: 200)
    }

    private func rotateButton(_ label: String, _ symbol: String, by degrees: CGFloat) -> some View {
        Button(label, systemImage: symbol) { sheet.rotate(by: degrees) }.labelStyle(.iconOnly).help(label)
    }

    private func adjustment(
        _ title: String, _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double> = -100...100
    ) -> some View {
        GridRow {
            Text(title)
            HStack {
                slider(label, value, range)
                number(label, value, "%", range)
            }
        }
    }
}
