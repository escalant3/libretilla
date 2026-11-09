import AppKit
import LibretillaDocx
import SwiftUI

/// The formatting bar under the toolbar (bootstrap §6), Office 97 style, built from standard
/// controls: Zoom · Style · Font · Size · B I U S · Text colour · Highlight · Alignment · Lists ·
/// Indent · Line spacing. It reflects the selection and sends commands to the editor.
///
/// It fits any window width: groups that don't fit are hidden from the right, and a » button offers them
/// as menus (the Format menu's own items), so a thin window works as a note-taking strip.
final class FormatBarViewController: NSTitlebarAccessoryViewController {
    /// The bar's groups, left to right; the rightmost go into the overflow menu first.
    enum Group: CaseIterable, Hashable {
        case zoom, style, font, character, color, alignment, lists, spacing
    }

    /// Receives the commands. Set before the bar is shown.
    weak var target: EditorViewController? {
        didSet { model.editor = target }
    }
    let model = FormatBarModel()
    /// The groups currently in the overflow menu.
    var hiddenGroups: [Group] { model.hiddenGroups }
    /// Each group's width when shown (measured once).
    private var groupWidths: [CGFloat] = []
    private var fitScheduled = false
    static let spacing: CGFloat = 6
    static let sideInset: CGFloat = 10

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let hosting = NSHostingView(rootView: FormatBar(model: model))
        // As tall as the controls; never wider than the window (groups that don't fit go into the » menu).
        hosting.sizingOptions = [.minSize, .maxSize]
        hosting.setAccessibilityRole(.toolbar)
        hosting.setAccessibilityLabel(String(localized: "Format bar"))
        hosting.setAccessibilityIdentifier("formatBar")
        hosting.frame.size = hosting.fittingSize
        view = hosting
    }

    // MARK: Fitting the width

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleFit()
    }

    /// Fits after layout, never during it: changing the bar in a layout pass makes AppKit abort.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fit(width: self.view.bounds.width)
        }
    }

    /// Shows as many groups as fit in `width`, left to right, and puts the rest in the overflow menu.
    func fit(width: CGFloat) {
        loadViewIfNeeded()
        if groupWidths.isEmpty {
            groupWidths = Group.allCases.map { group in
                NSHostingView(rootView: FormatBarGroup(group: group, model: model).controlSize(.small)).fittingSize
                    .width
            }
        }
        let overflowWidth = NSHostingView(rootView: OverflowButton(hidden: [.spacing]).controlSize(.small))
            .fittingSize.width
        let shown = Self.groupsThatFit(
            widths: groupWidths, overflowWidth: overflowWidth, in: width - 2 * Self.sideInset)
        let hidden = Array(Group.allCases[shown...])
        if hidden != model.hiddenGroups { model.hiddenGroups = hidden }
    }

    /// How many groups (from the left) fit in `available` points, leaving room for the » button unless all fit.
    static func groupsThatFit(widths: [CGFloat], overflowWidth: CGFloat, in available: CGFloat) -> Int {
        var used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let next = used + (i > 0 ? spacing : 0) + w
            let isLast = i == widths.count - 1
            guard next + (isLast ? 0 : overflowWidth + spacing) <= available else { return i }
            used = next
        }
        return widths.count
    }

    /// The hidden groups as the Format menu's own submenus (Style, Font, Text, List) plus zoom.
    static func overflowMenus(for hiddenGroups: [Group]) -> [NSMenu] {
        let hidden = Set(hiddenGroups)
        var menus: [NSMenu] = []
        if hidden.contains(.zoom) {
            let zoom = NSMenu(title: String(localized: "Zoom"))
            zoom.addItem(
                withTitle: String(localized: "Zoom In"), action: #selector(EditorViewController.zoomIn(_:)),
                keyEquivalent: "")
            zoom.addItem(
                withTitle: String(localized: "Zoom Out"), action: #selector(EditorViewController.zoomOut(_:)),
                keyEquivalent: "")
            zoom.addItem(
                withTitle: String(localized: "Actual Size"),
                action: #selector(EditorViewController.zoomToActualSize(_:)), keyEquivalent: "")
            menus.append(zoom)
        }
        if hidden.contains(.style) { menus.append(MainMenu.styleMenu()) }
        if !hidden.isDisjoint(with: [.font, .character, .color]) { menus.append(MainMenu.fontMenu()) }
        if !hidden.isDisjoint(with: [.alignment, .lists, .spacing]) { menus.append(MainMenu.textMenu()) }
        if hidden.contains(.lists) { menus.append(MainMenu.listMenu()) }
        // The copies of menu bar items carry no shortcuts: a pop-up button in the window would answer them first.
        for menu in menus { stripKeyEquivalents(menu) }
        return menus
    }

    private static func stripKeyEquivalents(_ menu: NSMenu) {
        for item in menu.items {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            if let sub = item.submenu { stripKeyEquivalents(sub) }
        }
    }

    static func zoomText(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

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

    // MARK: Reflecting the editor

    /// Shows the zoom (or Fit).
    func showZoom(_ zoom: CGFloat, fits: Bool = false) {
        model.zoom = fits ? EditorViewController.fitZoomItem : zoom
    }

    func update(_ format: SelectionFormat, bridge: AttributedStringBridge, editable: Bool) {
        model.update(format, styles: bridge.styles, editable: editable)
    }
}

/// What the format bar shows: the selection's formatting, the document's styles and the zoom.
@MainActor @Observable
final class FormatBarModel {
    struct StyleItem: Hashable {
        var key: String
        var title: String
    }

    @ObservationIgnored weak var editor: EditorViewController?
    var format = SelectionFormat()
    var editable = true
    /// The zoom, or `EditorViewController.fitZoomItem` for Fit.
    var zoom: CGFloat = 1
    var hiddenGroups: [FormatBarViewController.Group] = []
    /// The document's quick styles besides the standard ones.
    private(set) var extraStyles: [StyleItem] = []
    /// A style that isn't in the list (not a quick style), shown while it's selected.
    private(set) var otherStyle: StyleItem?
    private(set) var styleKey: String?

    /// The installed font families, and a font the document names but this Mac doesn't have (shown anyway).
    static let installedFamilies = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    private(set) var missingFamily: String?

    /// The zoom menu's levels, with a level from a pinch that isn't one of them while it lasts.
    var zoomLevels: [CGFloat] {
        let levels = EditorViewController.zoomLevels
        guard zoom != EditorViewController.fitZoomItem, !levels.contains(where: { abs($0 - zoom) < 0.005 }) else {
            return levels
        }
        return (levels + [zoom]).sorted()
    }

    /// The level the zoom menu shows (the listed level a pinch landed close to).
    var zoomSelection: CGFloat {
        zoomLevels.first { abs($0 - zoom) < 0.005 } ?? zoom
    }

    func update(_ format: SelectionFormat, styles: StyleSheet, editable: Bool) {
        if self.format != format { self.format = format }
        if self.editable != editable { self.editable = editable }

        // Standard styles, then the document's other quick styles.
        let extra = styles.styles.values
            .filter { s in
                s.type == "paragraph" && s.isQuickStyle
                    && !StyleChoice.standard.contains { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }
                    && s.name.caseInsensitiveCompare("List Paragraph") != .orderedSame
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { StyleItem(key: StyleChoice.document($0.id).key, title: $0.name) }
        if extra != extraStyles { extraStyles = extra }

        let key =
            StyleChoice.standard.first { StyleChoice.builtIn($0.name).matches(format.styleId, in: styles) }
            .map { StyleChoice.builtIn($0.name).key } ?? format.styleId.map { StyleChoice.document($0).key }
        var other: StyleItem?
        if let key, !extra.contains(where: { $0.key == key }), !key.hasPrefix("builtin:"),
            let id = format.styleId, let style = styles.styles[id]
        {
            other = StyleItem(key: key, title: style.name)
        }
        let shownKey = key.flatMap { k in
            k.hasPrefix("builtin:") || extra.contains { $0.key == k } || other != nil ? k : nil
        }
        if other != otherStyle { otherStyle = other }
        if shownKey != styleKey { styleKey = shownKey }

        let missing = format.fontFamily.flatMap { Self.installedFamilies.contains($0) ? nil : $0 }
        if missing != missingFamily { missingFamily = missing }
    }
}

struct FormatBar: View {
    let model: FormatBarModel

    var body: some View {
        HStack(spacing: FormatBarViewController.spacing) {
            ForEach(FormatBarViewController.Group.allCases.filter { !model.hiddenGroups.contains($0) }, id: \.self) {
                FormatBarGroup(group: $0, model: model)
            }
            if !model.hiddenGroups.isEmpty { OverflowButton(hidden: model.hiddenGroups) }
        }
        .controlSize(.small)
        .padding(.horizontal, FormatBarViewController.sideInset)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// One group of the format bar, with the separator before it (so hiding a group hides its separator too).
struct FormatBarGroup: View {
    let group: FormatBarViewController.Group
    let model: FormatBarModel

    private var editor: EditorViewController? { model.editor }
    private var format: SelectionFormat { model.format }

    var body: some View {
        HStack(spacing: FormatBarViewController.spacing) {
            switch group {
            case .zoom: zoom
            case .style:
                separator
                style
            case .font: font
            case .character:
                separator
                character
            case .color: color
            case .alignment:
                separator
                alignment
            case .lists:
                separator
                lists
            case .spacing: spacing
            }
        }
        .disabled(group != .zoom && !model.editable)
        .fixedSize()
    }

    private var separator: some View { Divider().frame(height: 16) }

    private var zoom: some View {
        PopUpPicker(
            label: String(localized: "Zoom"),
            items: [.option(String(localized: "Fit"), EditorViewController.fitZoomItem), .separator]
                + model.zoomLevels.map { .option(FormatBarViewController.zoomText($0), $0) },
            selection: model.zoomSelection
        ) { editor?.applyZoom($0) }
        .frame(width: 68)
    }

    private var style: some View {
        let standard = StyleChoice.standard.map { PopUpItem.option($0.title, StyleChoice.builtIn($0.name).key) }
        let extra = model.extraStyles.map { PopUpItem.option($0.title, $0.key) }
        let other = model.otherStyle.map { [PopUpItem.option($0.title, $0.key)] } ?? []
        return PopUpPicker(
            label: String(localized: "Paragraph style"),
            items: standard + (extra.isEmpty ? [] : [.separator] + extra) + other, selection: model.styleKey
        ) { editor?.applyParagraphStyle(key: $0) }
        .frame(width: 130)
    }

    @ViewBuilder private var font: some View {
        PopUpPicker(
            label: String(localized: "Font"),
            items: ([model.missingFamily].compactMap { $0 } + FormatBarModel.installedFamilies).map { .option($0, $0) },
            selection: format.fontFamily
        ) { editor?.applyFontFamily($0) }
        .frame(width: 150)
        FontSizeBox(size: format.fontSize) { editor?.applyFontSize($0) }
            .help(String(localized: "Font size"))
            .frame(width: 58)
    }

    private var character: some View {
        ControlGroup {
            toggle(String(localized: "Bold"), "bold", format.bold) { editor?.toggleBold(nil) }
            toggle(String(localized: "Italic"), "italic", format.italic) { editor?.toggleItalic(nil) }
            toggle(String(localized: "Underline"), "underline", format.underline) { editor?.toggleUnderline(nil) }
            toggle(String(localized: "Strikethrough"), "strikethrough", format.strike) {
                editor?.toggleStrikethrough(nil)
            }
        }
        .accessibilityLabel(String(localized: "Character style"))
    }

    @ViewBuilder private var color: some View {
        ColorPicker(
            String(localized: "Text color"),
            selection: Binding(
                get: { Color(nsColor: format.color ?? .textColor) }, set: { editor?.applyTextColor(NSColor($0)) }),
            supportsOpacity: false
        )
        .labelsHidden()
        .help(String(localized: "Text color"))
        PullDownButton(
            label: String(localized: "Highlight"), symbol: "highlighter", items: MainMenu.highlightItems,
            target: editor)
    }

    private var alignment: some View {
        let symbols = ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"]
        let labels = [
            String(localized: "Align Left"), String(localized: "Center"), String(localized: "Align Right"),
            String(localized: "Justify"),
        ]
        return Picker(
            String(localized: "Alignment"),
            selection: Binding(
                get: { format.alignment.flatMap { EditorViewController.alignments.firstIndex(of: $0) } },
                set: { $0.map { editor?.applyAlignment(at: $0) } })
        ) {
            ForEach(symbols.indices, id: \.self) { i in
                Image(systemName: symbols[i]).accessibilityLabel(labels[i]).help(labels[i]).tag(i as Int?)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(String(localized: "Alignment"))
    }

    @ViewBuilder private var lists: some View {
        ControlGroup {
            toggle(String(localized: "Bulleted List"), "list.bullet", format.list == .bullet) {
                editor?.toggleBulletedList(nil)
            }
            toggle(String(localized: "Numbered List"), "list.number", format.list == .numbered) {
                editor?.toggleNumberedList(nil)
            }
        }
        .accessibilityLabel(String(localized: "Lists"))
        ControlGroup {
            button(String(localized: "Decrease Indent"), "decrease.indent") { editor?.decreaseIndent(nil) }
            button(String(localized: "Increase Indent"), "increase.indent") { editor?.increaseIndent(nil) }
        }
        .accessibilityLabel(String(localized: "Indent"))
    }

    private var spacing: some View {
        PullDownButton(
            label: String(localized: "Line and paragraph spacing"), symbol: "arrow.up.and.down.text.horizontal",
            items: MainMenu.spacingItems, target: editor)
    }

    private func toggle(_ label: String, _ symbol: String, _ isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label(label, systemImage: symbol)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(label)
    }

    private func button(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: symbol) }.labelStyle(.iconOnly).help(label)
    }
}

enum PopUpItem<Value: Hashable>: Hashable {
    case option(String, Value)
    case separator
}

/// A pop-up menu of values. Not SwiftUI's menu `Picker`: that exposes no action to VoiceOver (accessibility audit).
private struct PopUpPicker<Value: Hashable>: NSViewRepresentable {
    let label: String
    var items: [PopUpItem<Value>]
    var selection: Value?
    var onSelect: (Value) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.isEnabled = context.environment.isEnabled
        if context.coordinator.items != items {
            context.coordinator.items = items
            button.removeAllItems()
            for item in items {
                switch item {
                case .option(let title, _):
                    // Through the menu: NSPopUpButton's addItem(withTitle:) drops repeated titles.
                    button.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
                case .separator: button.menu?.addItem(.separator())
                }
            }
        }
        let index = selection.flatMap { s in items.firstIndex { if case .option(_, s) = $0 { true } else { false } } }
        if let index { button.selectItem(at: index) } else { button.select(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    @MainActor final class Coordinator: NSObject {
        var items: [PopUpItem<Value>] = []
        var onSelect: (Value) -> Void
        init(onSelect: @escaping (Value) -> Void) { self.onSelect = onSelect }
        @objc func picked(_ sender: NSPopUpButton) {
            if case .option(_, let value) = items[safe: sender.indexOfSelectedItem] { onSelect(value) }
        }
    }
}

/// The font size box: a list of standard sizes, or any size typed in. SwiftUI has no combo box.
private struct FontSizeBox: NSViewRepresentable {
    var size: Double?
    var apply: (String) -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.addItems(withObjectValues: EditorViewController.standardSizes.map(FormatBarViewController.sizeText))
        box.numberOfVisibleItems = 16
        box.completes = false
        box.controlSize = .small
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        box.setAccessibilityLabel(String(localized: "Font size"))
        box.target = context.coordinator
        box.action = #selector(Coordinator.changed(_:))
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.apply = apply
        box.isEnabled = context.environment.isEnabled
        // Not while it's being typed in.
        if box.currentEditor() == nil { box.stringValue = size.map(FormatBarViewController.sizeText) ?? "" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(apply: apply) }

    @MainActor final class Coordinator: NSObject {
        var apply: (String) -> Void
        init(apply: @escaping (String) -> Void) { self.apply = apply }
        @objc func changed(_ sender: NSComboBox) { apply(sender.stringValue) }
    }
}

/// A button that pulls down a menu of `NSMenuItem`s: the menu bar's own items, which keep their checkmarks and
/// titles up to date as the selection changes. Not SwiftUI's `Menu`: that exposes no action to VoiceOver
/// (accessibility audit).
struct PullDownButton: NSViewRepresentable {
    let label: String
    let symbol: String
    var items: () -> [NSMenuItem]
    /// Receives the items' actions; nil sends them up the responder chain.
    weak var target: AnyObject?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = true
        button.controlSize = .small
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.items[0].image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        for item in items() {
            if item.action != nil, let target { item.target = target }
            menu.addItem(item)
        }
        button.menu = menu
        button.isEnabled = context.environment.isEnabled
    }
}

/// The » button: the groups that don't fit, as the menu bar's menus.
struct OverflowButton: View {
    var hidden: [FormatBarViewController.Group]

    var body: some View {
        PullDownButton(label: String(localized: "More formatting"), symbol: "chevron.right.2") {
            FormatBarViewController.overflowMenus(for: hidden).map { submenu in
                let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                return item
            }
        }
    }
}
