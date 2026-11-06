import AppKit

/// The quiet "Saved / Saving… / Couldn't save" label beside the title (bootstrap §5.4).
final class SaveStatusViewController: NSTitlebarAccessoryViewController {
    private let label = NSTextField(labelWithString: "")

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("saveStatus")
        // A trailing title-bar accessory takes its width from the view's frame, not from constraints: with a
        // zero frame macOS 26 lays it out 2 points wide, outside the window. `fitWidth()` sizes the frame to
        // the text each time it changes.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let trailing = label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.trailingInset)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.leadingInset),
            trailing,
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumLabelWidth),
        ])
        view = container
    }

    private static let leadingInset: CGFloat = 8
    private static let trailingInset: CGFloat = 12
    private static let maximumLabelWidth: CGFloat = 260

    private func fitWidth() {
        let text = ceil(min(label.intrinsicContentSize.width, Self.maximumLabelWidth))
        let width = Self.leadingInset + text + Self.trailingInset
        guard view.frame.width != width else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    func show(_ state: LibretillaDocument.SaveState, isDraft: Bool) {
        loadViewIfNeeded()
        let text: String
        var announce = false
        switch state {
        case .saved: text = isDraft ? String(localized: "Draft") : String(localized: "Saved")
        case .edited: text = isDraft ? String(localized: "Draft") : String(localized: "Edited")
        case .saving: text = String(localized: "Saving…")
        case .failed(let reason):
            text = String(localized: "Couldn’t save")
            label.toolTip = reason
            announce = true
        case .readOnly(let reason):
            text = String(localized: "Read-only")
            label.toolTip = String(localized: "Libretilla can’t safely save this document: \(reason).")
        }
        if case .failed = state {} else if case .readOnly = state {} else { label.toolTip = nil }
        label.stringValue = text
        label.textColor = announce ? .systemRed : .labelColor
        fitWidth()
        if announce {
            // VoiceOver announces failures only, not routine saves.
            NSAccessibility.post(
                element: label, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
