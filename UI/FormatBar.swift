import AppKit
import CartillaDocx

/// The formatting bar under the toolbar (bootstrap §6), Office 97 style, built from standard
/// controls: Zoom · Style · Font · Size · B I U S · Text colour · Highlight · Alignment · Lists ·
/// Indent · Line spacing. It reflects the selection and sends commands to the editor.
final class FormatBarViewController: NSTitlebarAccessoryViewController {
    /// Receives the commands (the editor). Set before the bar is shown.
    weak var target: AnyObject? {
        didSet { if isViewLoaded { retarget() } }
    }

    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeBox = NSComboBox()
    private let traits = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let highlight = NSPopUpButton(frame: .zero, pullsDown: true)
    private let alignment = NSSegmentedControl()
    private let lists = NSSegmentedControl()
    private let indent = NSSegmentedControl()
    private let spacing = NSPopUpButton(frame: .zero, pullsDown: true)

    private var styleSignature = ""
    private var installedFamilies = Set<String>()

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    override func loadView() {
        for level in EditorViewController.zoomLevels {
            zoomPopup.addItem(withTitle: Self.zoomText(level))
            zoomPopup.lastItem?.representedObject = level
        }
        zoomPopup.setAccessibilityLabel(String(localized: "Zoom"))
        zoomPopup.toolTip = String(localized: "Zoom")
        zoomPopup.action = #selector(EditorViewController.applyZoom(_:))
        zoomPopup.widthAnchor.constraint(equalToConstant: 68).isActive = true

        stylePopup.setAccessibilityLabel(String(localized: "Paragraph style"))
        stylePopup.toolTip = String(localized: "Paragraph style")
        stylePopup.action = #selector(EditorViewController.applyParagraphStyle(_:))
        stylePopup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        installedFamilies = Set(families)
        for family in families where !family.hasPrefix(".") {
            fontPopup.addItem(withTitle: family)
            fontPopup.lastItem?.representedObject = family
        }
        fontPopup.setAccessibilityLabel(String(localized: "Font"))
        fontPopup.toolTip = String(localized: "Font")
        fontPopup.action = #selector(EditorViewController.applyFontFamily(_:))
        fontPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        sizeBox.addItems(withObjectValues: EditorViewController.standardSizes.map { Self.sizeText($0) })
        sizeBox.numberOfVisibleItems = 16
        sizeBox.completes = false
        sizeBox.setAccessibilityLabel(String(localized: "Font size"))
        sizeBox.toolTip = String(localized: "Font size")
        sizeBox.action = #selector(EditorViewController.applyFontSize(_:))
        sizeBox.widthAnchor.constraint(equalToConstant: 58).isActive = true

        configure(
            traits, mode: .selectAny, action: #selector(EditorViewController.formatBarToggleTrait(_:)),
            segments: [
                ("bold", String(localized: "Bold")), ("italic", String(localized: "Italic")),
                ("underline", String(localized: "Underline")), ("strikethrough", String(localized: "Strikethrough")),
            ])

        colorWell.setAccessibilityLabel(String(localized: "Text color"))
        colorWell.toolTip = String(localized: "Text color")
        colorWell.action = #selector(EditorViewController.applyTextColor(_:))
        colorWell.color = .textColor

        highlight.isBordered = true
        highlight.setAccessibilityLabel(String(localized: "Highlight"))
        highlight.toolTip = String(localized: "Highlight")
        highlight.addItem(withTitle: "")
        highlight.lastItem?.image = NSImage(
            systemSymbolName: "highlighter", accessibilityDescription: String(localized: "Highlight"))
        highlight.addItem(withTitle: String(localized: "No Highlight"))
        highlight.lastItem?.action = #selector(EditorViewController.applyHighlight(_:))
        for (name, title) in Self.highlights {
            highlight.addItem(withTitle: title)
            let item = highlight.lastItem!
            item.representedObject = name
            item.action = #selector(EditorViewController.applyHighlight(_:))
            item.image = Self.swatch(AttributedStringBridge.highlightColor(name))
        }

        configure(
            alignment, mode: .selectOne, action: #selector(EditorViewController.applyAlignment(_:)),
            segments: [
                ("text.alignleft", String(localized: "Align Left")),
                ("text.aligncenter", String(localized: "Center")),
                ("text.alignright", String(localized: "Align Right")),
                ("text.justify", String(localized: "Justify")),
            ])
        configure(
            lists, mode: .selectAny, action: #selector(EditorViewController.formatBarToggleList(_:)),
            segments: [
                ("list.bullet", String(localized: "Bulleted List")),
                ("list.number", String(localized: "Numbered List")),
            ])
        configure(
            indent, mode: .momentary, action: #selector(EditorViewController.formatBarIndent(_:)),
            segments: [
                ("decrease.indent", String(localized: "Decrease Indent")),
                ("increase.indent", String(localized: "Increase Indent")),
            ])

        spacing.isBordered = true
        spacing.setAccessibilityLabel(String(localized: "Line and paragraph spacing"))
        spacing.toolTip = String(localized: "Line and paragraph spacing")
        spacing.addItem(withTitle: "")
        spacing.lastItem?.image = NSImage(
            systemSymbolName: "arrow.up.and.down.text.horizontal",
            accessibilityDescription: String(localized: "Line and paragraph spacing"))
        for item in MainMenu.spacingItems() { spacing.menu?.addItem(item) }

        let stack = NSStackView(views: [
            zoomPopup, Self.separator(), stylePopup, fontPopup, sizeBox, Self.separator(), traits, colorWell, highlight,
            Self.separator(),
            alignment, Self.separator(), lists, indent, spacing,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        for v in stack.arrangedSubviews { (v as? NSControl)?.controlSize = .small }
        sizeBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stylePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fontPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zoomPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.setAccessibilityRole(.toolbar)
        container.setAccessibilityLabel(String(localized: "Format bar"))
        container.setAccessibilityIdentifier("formatBar")
        view = container
        retarget()
    }

    private func configure(
        _ control: NSSegmentedControl, mode: NSSegmentedControl.SwitchTracking, action: Selector,
        segments: [(symbol: String, label: String)]
    ) {
        control.segmentCount = segments.count
        control.trackingMode = mode
        control.action = action
        control.segmentStyle = .automatic
        for (i, s) in segments.enumerated() {
            control.setImage(NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.label), forSegment: i)
            control.setToolTip(s.label, forSegment: i)
            control.setWidth(26, forSegment: i)
        }
    }

    private func retarget() {
        for control in [zoomPopup, stylePopup, fontPopup, sizeBox, traits, colorWell, alignment, lists, indent]
            as [NSControl]
        {
            control.target = target
        }
        for item in (highlight.menu?.items ?? []) + (spacing.menu?.items ?? []) where item.action != nil {
            item.target = target
        }
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    static func zoomText(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// Shows the zoom; a level from a pinch that isn't in the list is shown while it lasts.
    func showZoom(_ zoom: CGFloat) {
        loadViewIfNeeded()
        while let extra = zoomPopup.itemArray.firstIndex(where: { $0.tag == Self.pinchZoomTag }) {
            zoomPopup.removeItem(at: extra)
        }
        if let item = zoomPopup.itemArray.first(where: { abs(($0.representedObject as? CGFloat ?? 0) - zoom) < 0.005 })
        {
            zoomPopup.select(item)
            return
        }
        let index = EditorViewController.zoomLevels.firstIndex { $0 > zoom } ?? EditorViewController.zoomLevels.count
        zoomPopup.insertItem(withTitle: Self.zoomText(zoom), at: index)
        let item = zoomPopup.item(at: index)!
        item.tag = Self.pinchZoomTag
        item.representedObject = zoom
        zoomPopup.select(item)
    }
    private static let pinchZoomTag = -1

    static func sizeText(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
    }

    static let highlights: [(String, String)] = [
        ("yellow", String(localized: "Yellow")), ("green", String(localized: "Green")),
        ("cyan", String(localized: "Turquoise")), ("magenta", String(localized: "Pink")),
        ("blue", String(localized: "Blue")), ("red", String(localized: "Red")),
        ("lightGray", String(localized: "Gray")),
    ]

    static func swatch(_ color: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            (color ?? .clear).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }

    // MARK: Reflecting the selection

    func update(_ format: SelectionFormat, bridge: AttributedStringBridge, editable: Bool) {
        loadViewIfNeeded()
        rebuildStyles(bridge.styles)
        let key =
            StyleChoice.standard.first {
                StyleChoice.builtIn($0.name).matches(format.styleId, in: bridge.styles)
            }.map { StyleChoice.builtIn($0.name).key } ?? format.styleId.map { StyleChoice.document($0).key }
        if let key, let i = stylePopup.menu?.items.firstIndex(where: { $0.representedObject as? String == key }) {
            stylePopup.selectItem(at: i)
        } else if let id = format.styleId, let style = bridge.styles.styles[id] {
            // A style that isn't in the list (not a quick style): show it while it's selected.
            stylePopup.addItem(withTitle: style.name)
            stylePopup.lastItem?.representedObject = StyleChoice.document(id).key
            stylePopup.lastItem?.target = target
            stylePopup.select(stylePopup.lastItem)
            styleSignature = ""
        } else {
            stylePopup.select(nil)
        }

        if let family = format.fontFamily {
            if fontPopup.item(withTitle: family) == nil {
                // A font the document names but this Mac doesn't have: show it anyway.
                fontPopup.insertItem(withTitle: family, at: 0)
                fontPopup.item(at: 0)?.representedObject = family
            }
            fontPopup.selectItem(withTitle: family)
        } else {
            fontPopup.select(nil)
        }
        if sizeBox.currentEditor() == nil {
            sizeBox.stringValue = format.fontSize.map(Self.sizeText) ?? ""
        }
        for (i, on) in [format.bold, format.italic, format.underline, format.strike].enumerated() {
            traits.setSelected(on, forSegment: i)
        }
        colorWell.color = format.color ?? .textColor
        let a = format.alignment.flatMap { EditorViewController.alignments.firstIndex(of: $0) } ?? -1
        alignment.selectedSegment = a
        lists.setSelected(format.list == .bullet, forSegment: 0)
        lists.setSelected(format.list == .numbered, forSegment: 1)
        for control in [
            stylePopup, fontPopup, sizeBox, traits, colorWell, highlight, alignment, lists, indent, spacing,
        ]
            as [NSControl]
        {
            control.isEnabled = editable
        }
    }

    private func rebuildStyles(_ styles: StyleSheet) {
        // Standard styles, then the document's other quick styles.
        let extra = styles.styles.values
            .filter { s in
                s.type == "paragraph" && s.isQuickStyle
                    && !StyleChoice.standard.contains { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }
                    && s.name.caseInsensitiveCompare("List Paragraph") != .orderedSame
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let signature = extra.map(\.id).joined(separator: "\u{1}")
        guard signature != styleSignature || stylePopup.numberOfItems == 0 else { return }
        styleSignature = signature
        stylePopup.removeAllItems()
        for (name, title) in StyleChoice.standard {
            stylePopup.addItem(withTitle: title)
            stylePopup.lastItem?.representedObject = StyleChoice.builtIn(name).key
        }
        if !extra.isEmpty { stylePopup.menu?.addItem(.separator()) }
        for s in extra {
            stylePopup.addItem(withTitle: s.name)
            stylePopup.lastItem?.representedObject = StyleChoice.document(s.id).key
        }
        retarget()
    }
}
