import AppKit
import LibretillaDocx
import SwiftUI

/// Format ▸ Paragraph…: exact alignment, indents, spacing and line spacing, as in Word's Paragraph dialog. It
/// starts from the first selected paragraph; `onDone` gets the changes for the values that were changed (so
/// the others keep each paragraph's own), or nil on Cancel or when nothing changed.
@MainActor @Observable
final class ParagraphSheet {
    enum Special: Hashable { case none, firstLine, hanging }
    enum LineRule: Hashable { case multiple, atLeast, exactly }

    struct Values: Equatable {
        /// `left`, `center`, `right` or `both`.
        var alignment = "left"
        /// Points.
        var left: Double = 0
        var right: Double = 0
        var special = Special.none
        /// The first line or hanging indent, points.
        var by: Double = 0
        var before: Double = 0
        var after: Double = 0
        var lineRule = LineRule.multiple
        /// Lines for `multiple`, points otherwise.
        var line: Double = 1

        init() {}

        /// The values shown for a paragraph's effective properties.
        init(_ p: ParagraphProperties) {
            alignment =
                switch p.alignment {
                case "center": "center"
                case "right", "end": "right"
                case "both", "distribute": "both"
                default: "left"
                }
            left = p.indentLeft ?? 0
            right = p.indentRight ?? 0
            let first = p.firstLine ?? 0
            special = first > 0 ? .firstLine : first < 0 ? .hanging : .none
            by = abs(first)
            before = p.spaceBefore ?? 0
            after = p.spaceAfter ?? 0
            switch p.lineRule ?? "auto" {
            case "exact": lineRule = .exactly
            case "atLeast": lineRule = .atLeast
            default: lineRule = .multiple
            }
            line = p.line ?? 1
        }

        var firstLine: Double {
            switch special {
            case .none: 0
            case .firstLine: by
            case .hanging: -by
            }
        }
    }

    var values: Values
    @ObservationIgnored private let original: Values
    /// Points per unit the indents are shown in (Settings ▸ Ruler units). Spacing is in points, as in Word.
    @ObservationIgnored let unit: (points: CGFloat, symbol: String, digits: Int)
    @ObservationIgnored var onDone: (([ParagraphChange]?) -> Void)?
    @ObservationIgnored private(set) var window: NSWindow?

    /// Word's limits: indents within ±22″, spacing up to 1584 pt, line spacing up to 132 lines or 1584 pt.
    static let indentLimit: Double = 1584
    static let spacingLimit: Double = 1584

    init(paragraph: ParagraphProperties, unit: Preferences.RulerUnit = Preferences.rulerUnit) {
        let values = Values(paragraph)
        self.values = values
        original = values
        self.unit = unit.display
    }

    /// Shows the sheet on `parent`; `onEnd` runs once it has gone.
    func present(on parent: NSWindow, onEnd: @escaping @MainActor () -> Void) {
        window = Sheet.present(
            String(localized: "Paragraph"), on: parent, content: ParagraphView(sheet: self), onEnd: onEnd)
    }

    // MARK: Values as the fields show them

    /// An indent (points) in the ruler's units.
    func indent(_ keyPath: WritableKeyPath<Values, Double>) -> Binding<Double> {
        Binding(
            get: { self.values[keyPath: keyPath] / Double(self.unit.points) },
            set: { self.values[keyPath: keyPath] = ($0 * Double(self.unit.points) * 20).rounded() / 20 })
    }

    var indentRange: ClosedRange<Double> {
        -Self.indentLimit / Double(unit.points)...Self.indentLimit / Double(unit.points)
    }

    var byRange: ClosedRange<Double> { 0...Self.indentLimit / Double(unit.points) }

    var lineRange: ClosedRange<Double> {
        values.lineRule == .multiple ? 0.06...132 : 0.7...Self.spacingLimit
    }

    /// Switching between lines and points keeps the spacing about the same (12 pt a line, as Word does).
    var lineRule: LineRule {
        get { values.lineRule }
        set {
            guard newValue != values.lineRule else { return }
            if values.lineRule == .multiple {
                values.line = (values.line * 12).rounded()
            } else if newValue == .multiple {
                values.line = max(1, (values.line / 12 * 4).rounded() / 4)
            }
            values.lineRule = newValue
        }
    }

    /// The changes from where the sheet started.
    var changes: [ParagraphChange] {
        var out: [ParagraphChange] = []
        let v = values
        let o = original
        if v.alignment != o.alignment { out.append(.alignment(v.alignment)) }
        if v.left != o.left || v.right != o.right || v.firstLine != o.firstLine {
            out.append(.indents(left: v.left, right: v.right, firstLine: v.firstLine))
        }
        if v.before != o.before { out.append(.spaceBefore(v.before)) }
        if v.after != o.after { out.append(.spaceAfter(v.after)) }
        if v.lineRule != o.lineRule || v.line != o.line {
            switch v.lineRule {
            case .multiple: out.append(.lineSpacing(v.line))
            case .atLeast: out.append(.lineHeight(v.line, atLeast: true))
            case .exactly: out.append(.lineHeight(v.line, atLeast: false))
            }
        }
        return out
    }

    // MARK: Closing

    private func close(with result: [ParagraphChange]?) {
        let done = onDone
        onDone = nil
        done?(result)
        Sheet.end(window)
    }

    func ok() {
        // Commit a field still being typed in.
        window?.makeFirstResponder(nil)
        let changes = changes
        close(with: changes.isEmpty ? nil : changes)
    }

    func cancel() { close(with: nil) }
}

private struct ParagraphView: View {
    @Bindable var sheet: ParagraphSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text(String(localized: "Alignment:")).gridColumnAlignment(.trailing)
                    Picker(String(localized: "Alignment"), selection: $sheet.values.alignment) {
                        Text(String(localized: "Left")).tag("left")
                        Text(String(localized: "Centered")).tag("center")
                        Text(String(localized: "Right")).tag("right")
                        Text(String(localized: "Justified")).tag("both")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                section(String(localized: "Indentation"))
                GridRow {
                    Text(String(localized: "Left:"))
                    unitField(String(localized: "Left indent"), sheet.indent(\.left), sheet.indentRange)
                }
                GridRow {
                    Text(String(localized: "Right:"))
                    unitField(String(localized: "Right indent"), sheet.indent(\.right), sheet.indentRange)
                }
                GridRow {
                    Text(String(localized: "Special:"))
                    HStack {
                        Picker(String(localized: "Special indent"), selection: $sheet.values.special) {
                            Text(String(localized: "None")).tag(ParagraphSheet.Special.none)
                            Text(String(localized: "First line")).tag(ParagraphSheet.Special.firstLine)
                            Text(String(localized: "Hanging")).tag(ParagraphSheet.Special.hanging)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if sheet.values.special != .none {
                            Text(String(localized: "By:"))
                            unitField(String(localized: "Special indent by"), sheet.indent(\.by), sheet.byRange)
                        }
                    }
                }
                section(String(localized: "Spacing"))
                GridRow {
                    Text(String(localized: "Before:"))
                    points(String(localized: "Space before"), $sheet.values.before)
                }
                GridRow {
                    Text(String(localized: "After:"))
                    points(String(localized: "Space after"), $sheet.values.after)
                }
                GridRow {
                    Text(String(localized: "Line spacing:"))
                    HStack {
                        Picker(String(localized: "Line spacing rule"), selection: $sheet.lineRule) {
                            Text(String(localized: "Multiple")).tag(ParagraphSheet.LineRule.multiple)
                            Text(String(localized: "At least")).tag(ParagraphSheet.LineRule.atLeast)
                            Text(String(localized: "Exactly")).tag(ParagraphSheet.LineRule.exactly)
                        }
                        .labelsHidden()
                        .fixedSize()
                        HStack(spacing: 6) {
                            NumberField(
                                label: String(localized: "Line spacing"), value: $sheet.values.line, digits: 2,
                                range: sheet.lineRange)
                            Text(
                                sheet.values.lineRule == .multiple
                                    ? String(localized: "lines") : String(localized: "pt")
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SheetButtons(cancel: sheet.cancel, confirmTitle: String(localized: "OK"), confirm: sheet.ok)
        }
        .padding(20)
        .fixedSize()
    }

    private func section(_ title: String) -> some View {
        GridRow {
            Text(title).font(.headline).gridCellColumns(2).padding(.top, 6)
        }
    }

    private func unitField(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            NumberField(label: label, value: value, digits: sheet.unit.digits, range: range)
            Text(sheet.unit.symbol).foregroundStyle(.secondary)
        }
    }

    private func points(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            NumberField(label: label, value: value, digits: 1, range: 0...ParagraphSheet.spacingLimit)
            Text(String(localized: "pt")).foregroundStyle(.secondary)
        }
    }
}
