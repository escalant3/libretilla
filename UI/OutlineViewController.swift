import AppKit

/// The outline sidebar (bootstrap §6, View ▸ Show Outline ⌃⌘S): the document's headings, as in Google Docs.
/// Clicking one moves the caret to it; the heading the caret is under is selected.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when the user picks a heading.
    var onSelect: ((OutlineHeading) -> Void)?

    private(set) var headings: [OutlineHeading] = []
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: String(localized: "Headings you add to the document appear here."))
    /// The smallest level shown, so a document without a Title isn't indented one step for nothing.
    private var baseLevel = 0

    override func loadView() {
        let column = NSTableColumn(identifier: .init("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.usesAutomaticRowHeights = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.setAccessibilityLabel(String(localized: "Outline"))
        tableView.setAccessibilityIdentifier("outline")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.alignment = .center

        let container = NSView()
        for v in [scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    /// Shows `headings`, keeping the table as it is when nothing changed (typing in body text).
    func show(_ headings: [OutlineHeading]) {
        loadViewIfNeeded()
        emptyLabel.isHidden = !headings.isEmpty
        guard headings != self.headings else { return }
        let sameTitles =
            headings.count == self.headings.count
            && zip(headings, self.headings).allSatisfy { $0.title == $1.title && $0.level == $1.level }
        self.headings = headings
        baseLevel = headings.map(\.level).min() ?? 0
        // Only offsets moved (typing above a heading): the rows look the same.
        if !sameTitles {
            let selected = tableView.selectedRow
            tableView.reloadData()
            if selected >= 0, selected < headings.count { select(row: selected) }
        }
    }

    /// Selects the heading the caret at `location` is under.
    func followCaret(at location: Int) {
        guard isViewLoaded else { return }
        select(row: DocumentOutline.index(of: location, in: headings) ?? -1)
    }

    private func select(row: Int) {
        // Selecting rows in code sends no action: only a click (or Return) jumps.
        guard row != tableView.selectedRow else { return }
        if row < 0 {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < headings.count else { return }
        onSelect?(headings[row])
    }

    // MARK: Keyboard: Return or Space jumps to the selected heading.

    override func keyDown(with event: NSEvent) {
        if ["\r", " "].contains(event.charactersIgnoringModifiers), tableView.selectedRow >= 0 {
            onSelect?(headings[tableView.selectedRow])
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("headingCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? HeadingCell ?? HeadingCell()
        cell.identifier = id
        let heading = headings[row]
        cell.configure(heading, indent: heading.level - baseLevel)
        return cell
    }

    final class HeadingCell: NSTableCellView {
        private let label = NSTextField(labelWithString: "")
        private var leading: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
            label.cell?.truncatesLastVisibleLine = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
            // Not `textField = label`: AppKit would draw a selected, unfocused row's text in the accent colour,
            // which fails the contrast audit on the gray selection. `backgroundStyle` sets the colour instead.
            leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
            NSLayoutConstraint.activate([
                leading,
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private var baseColor = NSColor.labelColor

        /// A selected row that isn't focused keeps its own text colour: AppKit's accent-coloured text on the
        /// gray selection doesn't have enough contrast (accessibility audit).
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : baseColor }
        }

        func configure(_ heading: OutlineHeading, indent: Int) {
            label.stringValue = heading.title
            leading.constant = 2 + CGFloat(min(indent, 5)) * 12
            // Top-level headings stand out a little, as in Google Docs.
            label.font = .systemFont(
                ofSize: NSFont.systemFontSize, weight: indent == 0 ? .semibold : .regular)
            // One text colour for every level: the secondary gray fails the contrast audit on the sidebar.
            label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : baseColor
            setAccessibilityLabel(heading.title)
            label.setAccessibilityValue(
                heading.level == 0
                    ? String(localized: "Title") : String(localized: "Heading level \(heading.level)"))
        }
    }
}
