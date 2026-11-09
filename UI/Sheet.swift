import AppKit
import SwiftUI

/// The document window's sheets (Format ▸ Picture…, Edit Table…, Header and Footer…, links, Insert Table…) are
/// SwiftUI views in a window of their own, which the editor shows with `NSWindow.beginSheet`.
@MainActor
enum Sheet {
    /// A window showing `content`, as big as it needs (or resizable from that size).
    static func window(_ title: String, resizable: Bool = false, content: some View) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = resizable ? [.titled, .resizable] : [.titled]
        return window
    }

    /// Ends a sheet, or closes the window when it isn't one (tests use sheets that are never shown).
    static func end(_ window: NSWindow?) {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    /// Shows `content` as a sheet on `parent`; `onEnd` runs once it has gone.
    static func present(
        _ title: String, on parent: NSWindow, content: some View, onEnd: @escaping @MainActor () -> Void = {}
    ) -> NSWindow {
        let window = window(title, content: content)
        parent.beginSheet(window) { _ in MainActor.assumeIsolated { onEnd() } }
        return window
    }
}

/// The buttons along the bottom of a sheet: `leading` on the left, Cancel (Escape) and the default action
/// (Return) on the right.
struct SheetButtons<Leading: View>: View {
    var cancel: () -> Void
    var confirmTitle: String
    var confirmShortcut = KeyboardShortcut.defaultAction
    var confirm: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack {
            leading
            Spacer()
            Button(String(localized: "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: confirm).keyboardShortcut(confirmShortcut)
        }
    }
}

extension SheetButtons where Leading == EmptyView {
    init(cancel: @escaping () -> Void, confirmTitle: String, confirm: @escaping () -> Void) {
        self.init(cancel: cancel, confirmTitle: confirmTitle, confirm: confirm) { EmptyView() }
    }
}

/// A number typed in a field, applied as it's typed (each number that parses) and shown again as stored when
/// the field is left or Return is pressed.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var digits = 0
    var range: ClosedRange<Double>
    var width: CGFloat = 64
    @State private var text = ""
    @FocusState private var focused: Bool

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        f.isLenient = true
        return f
    }

    private func show() { text = formatter.string(from: NSNumber(value: value)) ?? "" }

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onAppear(perform: show)
            .onSubmit(show)
            .onChange(of: value) { if !focused { show() } }
            .onChange(of: focused) { if !focused { show() } }
            .onChange(of: text) {
                guard focused, let n = formatter.number(from: text)?.doubleValue else { return }
                let clamped = min(max(n, range.lowerBound), range.upperBound)
                if clamped != value { value = clamped }
            }
    }
}
