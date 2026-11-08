import AppKit
import LibretillaDocx

/// Format ▸ Picture…: a sheet for a picture's size, rotation, brightness, contrast and opacity, all of which a
/// .docx stores (`PictureFormat`). Changes show in the document as they're made (`onChange`); `onDone` gets
/// the final format, or nil on Cancel.
final class PictureFormatController: NSWindowController, NSTextFieldDelegate {
    private(set) var format: PictureFormat
    private let original: PictureFormat
    private let naturalSize: CGSize
    /// Points per unit shown (Settings ▸ Ruler units).
    private let unit: (points: CGFloat, symbol: String, digits: Int)
    var onChange: ((PictureFormat) -> Void)?
    var onDone: ((PictureFormat?) -> Void)?

    /// Word's limits for a picture's width and height.
    static let maximumSide: CGFloat = 1584
    static let minimumSide: CGFloat = 1

    let widthField = NSTextField()
    let heightField = NSTextField()
    let keepAspectRatio = NSButton(checkboxWithTitle: String(localized: "Keep aspect ratio"), target: nil, action: nil)
    let rotationSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    let rotationField = NSTextField()
    let brightnessSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let brightnessField = NSTextField()
    let contrastSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let contrastField = NSTextField()
    let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let opacityField = NSTextField()

    init(format: PictureFormat, naturalSize: CGSize, unit: Preferences.RulerUnit = Preferences.rulerUnit) {
        self.format = format
        original = format
        self.naturalSize = naturalSize
        self.unit =
            switch unit {
            case .points: (1, String(localized: "pt"), 0)
            case .inches: (72, String(localized: "in"), 2)
            case .centimeters: (72 / 2.54, String(localized: "cm"), 2)
            }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.title = String(localized: "Format Picture")
        super.init(window: window)
        buildWindow()
        showFormat()
        // As wide and tall as its controls need (labels and units vary with the language and ruler units).
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func numberField(_ field: NSTextField, digits: Int, min: Double, max: Double, label: String) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        formatter.isLenient = true
        field.formatter = formatter
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
    }

    private func slider(_ slider: NSSlider, label: String) {
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel(label)
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func suffix(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        return s
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        return b
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        let maxSide = Double(Self.maximumSide / unit.points)
        let minSide = Double(Self.minimumSide / unit.points)
        numberField(widthField, digits: unit.digits, min: minSide, max: maxSide, label: String(localized: "Width"))
        numberField(heightField, digits: unit.digits, min: minSide, max: maxSide, label: String(localized: "Height"))
        numberField(rotationField, digits: 0, min: -360, max: 360, label: String(localized: "Rotation"))
        numberField(brightnessField, digits: 0, min: -100, max: 100, label: String(localized: "Brightness"))
        numberField(contrastField, digits: 0, min: -100, max: 100, label: String(localized: "Contrast"))
        numberField(opacityField, digits: 0, min: 0, max: 100, label: String(localized: "Opacity"))
        slider(rotationSlider, label: String(localized: "Rotation"))
        slider(brightnessSlider, label: String(localized: "Brightness"))
        slider(contrastSlider, label: String(localized: "Contrast"))
        slider(opacitySlider, label: String(localized: "Opacity"))
        keepAspectRatio.state = .on

        let rotateLeft = NSButton(
            image: NSImage(
                systemSymbolName: "rotate.left", accessibilityDescription: String(localized: "Rotate Left"))!,
            target: self, action: #selector(rotateLeft(_:)))
        rotateLeft.toolTip = String(localized: "Rotate Left")
        let rotateRight = NSButton(
            image: NSImage(
                systemSymbolName: "rotate.right", accessibilityDescription: String(localized: "Rotate Right"))!,
            target: self, action: #selector(rotateRight(_:)))
        rotateRight.toolTip = String(localized: "Rotate Right")

        let grid = NSGridView(views: [
            [label(String(localized: "Width:")), row([widthField, suffix(unit.symbol)])],
            [label(String(localized: "Height:")), row([heightField, suffix(unit.symbol)])],
            [
                NSGridCell.emptyContentView,
                row([keepAspectRatio, button(String(localized: "Original Size"), #selector(originalSize(_:)))]),
            ],
            [
                label(String(localized: "Rotation:")),
                row([rotationSlider, rotationField, suffix("°"), rotateLeft, rotateRight]),
            ],
            [label(String(localized: "Brightness:")), row([brightnessSlider, brightnessField, suffix("%")])],
            [label(String(localized: "Contrast:")), row([contrastSlider, contrastField, suffix("%")])],
            [label(String(localized: "Opacity:")), row([opacitySlider, opacityField, suffix("%")])],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 3).topPadding = 8

        let reset = button(String(localized: "Reset"), #selector(reset(_:)))
        reset.toolTip = String(localized: "Back to the picture's own size, unturned and unadjusted")
        let cancel = button(String(localized: "Cancel"), #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button(String(localized: "OK"), #selector(ok(_:)))
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = row([reset, spacer, cancel, ok])

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    // MARK: Showing the format

    /// Rotation as the slider shows it: −180…180.
    private static func signed(_ rotation: CGFloat) -> Double { Double(rotation > 180 ? rotation - 360 : rotation) }

    private func showFormat(except editing: NSControl? = nil) {
        func set(_ field: NSTextField, _ value: Double) {
            if field !== editing { field.objectValue = NSNumber(value: value) }
        }
        set(widthField, Double(format.size.width / unit.points))
        set(heightField, Double(format.size.height / unit.points))
        set(rotationField, Self.signed(format.rotation).rounded())
        set(brightnessField, Double(format.brightness * 100).rounded())
        set(contrastField, Double(format.contrast * 100).rounded())
        set(opacityField, Double(format.opacity * 100).rounded())
        rotationSlider.doubleValue = Self.signed(format.rotation)
        brightnessSlider.doubleValue = Double(format.brightness * 100)
        contrastSlider.doubleValue = Double(format.contrast * 100)
        opacitySlider.doubleValue = Double(format.opacity * 100)
    }

    private func update(_ change: (inout PictureFormat) -> Void, editing: NSControl? = nil) {
        var new = format
        change(&new)
        guard new != format else { return }
        format = new
        showFormat(except: editing)
        onChange?(format)
    }

    // MARK: Changes

    private static func clampedSide(_ v: CGFloat) -> CGFloat { min(max(v, minimumSide), maximumSide) }

    /// Sets the width (points), and the height with it when the aspect ratio is kept.
    func setWidth(_ width: CGFloat, editing: NSControl? = nil) {
        update(
            { f in
                let w = Self.clampedSide(width)
                if keepAspectRatio.state == .on, f.size.width > 0 {
                    f.size = CGSize(width: w, height: Self.clampedSide((f.size.height * w / f.size.width).rounded()))
                } else {
                    f.size.width = w
                }
            }, editing: editing)
    }

    /// Sets the height (points), and the width with it when the aspect ratio is kept.
    func setHeight(_ height: CGFloat, editing: NSControl? = nil) {
        update(
            { f in
                let h = Self.clampedSide(height)
                if keepAspectRatio.state == .on, f.size.height > 0 {
                    f.size = CGSize(width: Self.clampedSide((f.size.width * h / f.size.height).rounded()), height: h)
                } else {
                    f.size.height = h
                }
            }, editing: editing)
    }

    private func value(of field: NSTextField) -> CGFloat? {
        guard let formatter = field.formatter as? NumberFormatter,
            let n = formatter.number(from: field.stringValue)
        else { return nil }
        return CGFloat(n.doubleValue)
    }

    private func apply(_ field: NSTextField, live: Bool) {
        guard let v = value(of: field) else { return }
        let editing = live ? field : nil
        switch field {
        case widthField: setWidth(v * unit.points, editing: editing)
        case heightField: setHeight(v * unit.points, editing: editing)
        case rotationField: update({ $0.rotation = PictureFormat.normalized(v) }, editing: editing)
        case brightnessField: update({ $0.brightness = min(max(v / 100, -1), 1) }, editing: editing)
        case contrastField: update({ $0.contrast = min(max(v / 100, -1), 1) }, editing: editing)
        case opacityField: update({ $0.opacity = min(max(v / 100, 0), 1) }, editing: editing)
        default: break
        }
        if !live { showFormat() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField { apply(field, live: true) }
    }

    @objc private func fieldChanged(_ sender: NSTextField) { apply(sender, live: false) }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue.rounded())
        switch sender {
        case rotationSlider: update { $0.rotation = PictureFormat.normalized(v) }
        case brightnessSlider: update { $0.brightness = v / 100 }
        case contrastSlider: update { $0.contrast = v / 100 }
        case opacitySlider: update { $0.opacity = v / 100 }
        default: break
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

    @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }

    /// The image's own size, scaled down (keeping its proportions) if it's bigger than Word allows.
    var originalPictureSize: CGSize {
        let w = max(naturalSize.width, Self.minimumSide)
        let h = max(naturalSize.height, Self.minimumSide)
        let scale = min(1, Self.maximumSide / max(w, h))
        return CGSize(width: Self.clampedSide((w * scale).rounded()), height: Self.clampedSide((h * scale).rounded()))
    }

    @objc func originalSize(_ sender: Any?) { update { $0.size = originalPictureSize } }

    @objc func reset(_ sender: Any?) { update { $0 = PictureFormat(size: originalPictureSize) } }

    // MARK: Closing

    private func close(with result: PictureFormat?) {
        guard let window, let parent = window.sheetParent else {
            onDone?(result)
            return
        }
        onDone?(result)
        onDone = nil
        parent.endSheet(window)
    }

    @objc func ok(_ sender: Any?) {
        // Commit a field still being typed in (Return reaches this button before the field).
        window?.makeFirstResponder(nil)
        close(with: format == original ? nil : format)
    }

    @objc func cancel(_ sender: Any?) {
        // Discard live changes from a field still being typed in.
        window?.endEditing(for: nil)
        close(with: nil)
    }
}
