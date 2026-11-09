import AppKit
import SwiftUI

/// The quiet "Saved / Saving… / Couldn't save" label beside the title (bootstrap §5.4).
final class SaveStatusViewController: NSTitlebarAccessoryViewController {
    private let hosting = NSHostingView(rootView: SaveStatusLabel(text: "", toolTip: nil, isFailure: false))

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        // A trailing title-bar accessory takes its width from the view's frame, not from constraints: with a
        // zero frame macOS 26 lays it out 2 points wide, outside the window. `show` sizes the frame to the text.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.setAccessibilityLabel(String(localized: "Save status"))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        view = container
    }

    func show(_ state: LibretillaDocument.SaveState, isDraft: Bool) {
        loadViewIfNeeded()
        var label = SaveStatusLabel(text: "", toolTip: nil, isFailure: false)
        switch state {
        case .saved: label.text = isDraft ? String(localized: "Draft") : String(localized: "Saved")
        case .edited: label.text = isDraft ? String(localized: "Draft") : String(localized: "Edited")
        case .saving: label.text = String(localized: "Saving…")
        case .failed(let reason):
            label.text = String(localized: "Couldn’t save")
            label.toolTip = reason
            label.isFailure = true
            // VoiceOver announces failures only, not routine saves.
            var announcement = AttributedString(label.text)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        case .readOnly(let reason):
            label.text = String(localized: "Read-only")
            label.toolTip = String(localized: "Libretilla can’t safely save this document: \(reason).")
        }
        hosting.rootView = label
        let width = label.width
        if view.frame.width != width { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
    }
}

struct SaveStatusLabel: View {
    var text: String
    var toolTip: String?
    var isFailure: Bool

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let insets = (leading: 8.0, trailing: 12.0)
    private static let maximumTextWidth = 260.0

    /// The width the label takes in the title bar.
    var width: CGFloat {
        let text = ceil(min((text as NSString).size(withAttributes: [.font: Self.font]).width, Self.maximumTextWidth))
        return Self.insets.leading + text + Self.insets.trailing
    }

    var body: some View {
        Text(text)
            .font(Font(Self.font))
            .foregroundStyle(isFailure ? Color.red : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(toolTip ?? "")
            .accessibilityIdentifier("saveStatus")
            .frame(maxWidth: Self.maximumTextWidth, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, Self.insets.leading)
            .padding(.trailing, Self.insets.trailing)
    }
}
