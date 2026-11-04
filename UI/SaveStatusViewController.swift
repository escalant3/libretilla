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
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("saveStatus")
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        view = container
    }

    func show(_ state: CartillaDocument.SaveState, isDraft: Bool) {
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
            label.toolTip = String(localized: "Cartilla can’t safely save this document: \(reason).")
        }
        if case .failed = state {} else if case .readOnly = state {} else { label.toolTip = nil }
        label.stringValue = text
        label.textColor = announce ? .systemRed : .secondaryLabelColor
        if announce {
            // VoiceOver announces failures only, not routine saves.
            NSAccessibility.post(
                element: label, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
