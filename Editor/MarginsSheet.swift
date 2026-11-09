import AppKit
import LibretillaDocx
import SwiftUI

/// File ▸ Margins…: the page's top, bottom, left and right margins, in the ruler's units. `onDone` gets the new
/// page setup, or nil on Cancel or when nothing changed.
@MainActor @Observable
final class MarginsSheet {
    private(set) var setup: PageSetup
    @ObservationIgnored private let original: PageSetup
    /// Points per unit shown (Settings ▸ Ruler units).
    @ObservationIgnored let unit: (points: CGFloat, symbol: String, digits: Int)
    @ObservationIgnored var onDone: ((PageSetup?) -> Void)?
    @ObservationIgnored private(set) var window: NSWindow?

    /// The narrowest text column (and shortest text area) the margins may leave, in points: half an inch.
    static let minimumText: CGFloat = 36

    init(setup: PageSetup, unit: Preferences.RulerUnit = Preferences.rulerUnit) {
        self.setup = setup
        original = setup
        self.unit = unit.display
    }

    /// Shows the sheet on `parent`; `onEnd` runs once it has gone.
    func present(on parent: NSWindow, onEnd: @escaping @MainActor () -> Void) {
        window = Sheet.present(
            String(localized: "Margins"), on: parent, content: MarginsView(sheet: self), onEnd: onEnd)
    }

    // MARK: Values as the fields show them

    enum Side: CaseIterable { case top, bottom, left, right }

    /// A margin in points (top and bottom as distances: Word's negative "may overlap the header" sign is kept on save).
    func points(_ side: Side) -> CGFloat {
        let m = setup.margins
        return switch side {
        case .top: m.top
        case .bottom: m.bottom
        case .left: m.left
        case .right: m.right
        }
    }

    /// The largest `side` may be (points) given the opposite margin.
    func maximum(_ side: Side) -> CGFloat {
        let page = setup.pageSize
        return switch side {
        case .top: page.height - points(.bottom) - Self.minimumText
        case .bottom: page.height - points(.top) - Self.minimumText
        case .left: page.width - points(.right) - Self.minimumText
        case .right: page.width - points(.left) - Self.minimumText
        }
    }

    /// Sets a margin in points, kept between 0 and `maximum(side)`, rounded to whole twips.
    func set(_ side: Side, points: CGFloat) {
        let twips = Int((min(max(points, 0), max(maximum(side), 0)) * 20).rounded())
        switch side {
        case .top: setup.top = twips
        case .bottom: setup.bottom = twips
        case .left: setup.left = twips
        case .right: setup.right = twips
        }
    }

    func value(_ side: Side) -> Binding<Double> {
        Binding(
            get: { Double(self.points(side) / self.unit.points) },
            set: { self.set(side, points: CGFloat($0) * self.unit.points) })
    }

    func range(_ side: Side) -> ClosedRange<Double> { 0...Double(max(maximum(side), 0) / unit.points) }

    /// Word's own margins for the paper: 1 inch all round on Letter-sized paper, Spanish Word's A4 margins otherwise.
    /// Turned with the paper in landscape, as Word does.
    func useDefaults() {
        let letterWidth = PageSetup.letter.width
        let d = min(setup.width, setup.height) == letterWidth ? PageSetup.letter : PageSetup.a4
        (setup.top, setup.bottom, setup.left, setup.right) =
            setup.isLandscape ? (d.left, d.right, d.top, d.bottom) : (d.top, d.bottom, d.left, d.right)
    }

    // MARK: Closing

    private func close(with result: PageSetup?) {
        let done = onDone
        onDone = nil
        done?(result)
        Sheet.end(window)
    }

    func ok() {
        // Commit a field still being typed in.
        window?.makeFirstResponder(nil)
        close(with: setup == original ? nil : setup)
    }

    func cancel() { close(with: nil) }
}

extension Preferences.RulerUnit {
    /// Points per unit, the unit's symbol, and the fraction digits sheets show it with.
    var display: (points: CGFloat, symbol: String, digits: Int) {
        switch self {
        case .points: (1, String(localized: "pt"), 0)
        case .inches: (72, String(localized: "in"), 2)
        case .centimeters: (72 / 2.54, String(localized: "cm"), 2)
        }
    }
}

private struct MarginsView: View {
    @Bindable var sheet: MarginsSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                row(String(localized: "Top:"), String(localized: "Top margin"), .top)
                row(String(localized: "Bottom:"), String(localized: "Bottom margin"), .bottom)
                row(String(localized: "Left:"), String(localized: "Left margin"), .left)
                row(String(localized: "Right:"), String(localized: "Right margin"), .right)
            }
            SheetButtons(cancel: sheet.cancel, confirmTitle: String(localized: "OK"), confirm: sheet.ok) {
                Button(String(localized: "Use Defaults"), action: sheet.useDefaults)
                    .help(String(localized: "Word's standard margins for this paper"))
            }
        }
        .padding(20)
        .frame(minWidth: 300)
        .fixedSize()
    }

    private func row(_ title: String, _ label: String, _ side: MarginsSheet.Side) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                NumberField(
                    label: label, value: sheet.value(side), digits: sheet.unit.digits, range: sheet.range(side))
                Text(sheet.unit.symbol).foregroundStyle(.secondary)
            }
        }
    }
}
