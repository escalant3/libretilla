import AppKit
import SwiftUI

/// The outline sidebar (bootstrap §6, View ▸ Show Outline ⌃⌘S): the document's headings, as in Google Docs.
/// Clicking one (or Return or Space on the selected one) moves the caret to it; the heading the caret is under
/// is selected.
@MainActor @Observable
final class OutlineModel {
    private(set) var headings: [OutlineHeading] = []
    /// The selected row.
    var selection: Int?

    /// The list's selection: a click selects and jumps; the arrow keys only select (Return or Space jumps).
    var userSelection: Int? {
        get { selection }
        set {
            selection = newValue
            if let type = NSApp.currentEvent?.type, [.leftMouseDown, .leftMouseUp].contains(type) { pick(newValue) }
        }
    }
    /// Called when the user picks a heading.
    @ObservationIgnored var onSelect: ((OutlineHeading) -> Void)?

    /// The smallest level shown, so a document without a Title isn't indented one step for nothing.
    var baseLevel: Int { headings.map(\.level).min() ?? 0 }

    /// Shows `headings`, keeping the list as it is when nothing changed (typing in body text).
    func show(_ headings: [OutlineHeading]) {
        guard headings != self.headings else { return }
        self.headings = headings
        if let selection, selection >= headings.count { self.selection = nil }
    }

    /// Selects the heading the caret at `location` is under.
    func followCaret(at location: Int) {
        let row = DocumentOutline.index(of: location, in: headings)
        if row != selection { selection = row }
    }

    func pick(_ row: Int?) {
        guard let row, headings.indices.contains(row) else { return }
        let heading = headings[row]
        // After the click is done with: the list takes the focus at the end of it, and the jump gives it to the text.
        DispatchQueue.main.async { [weak self] in self?.onSelect?(heading) }
    }
}

struct OutlineSidebar: View {
    @Bindable var model: OutlineModel

    var body: some View {
        List(selection: $model.userSelection) {
            // Rows are identified by position: offsets move as the text is typed, titles repeat.
            ForEach(Array(model.headings.enumerated()), id: \.offset) { row, heading in
                let indent = heading.level - model.baseLevel
                Text(heading.title)
                    // Top-level headings stand out a little, as in Google Docs.
                    .fontWeight(indent == 0 ? .semibold : .regular)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, CGFloat(min(indent, 5)) * 12)
                    .padding(.vertical, 3)
                    .accessibilityLabel(heading.title)
                    .accessibilityValue(
                        heading.level == 0
                            ? String(localized: "Title") : String(localized: "Heading level \(heading.level)")
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.pick(row) }
                    .tag(row)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(String(localized: "Outline"))
        .accessibilityIdentifier("outline")
        .onKeyPress(keys: [.return, .space]) { _ in
            guard model.selection != nil else { return .ignored }
            model.pick(model.selection)
            return .handled
        }
        .overlay {
            if model.headings.isEmpty {
                Text(String(localized: "Headings you add to the document appear here."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }
}
