import AppKit

/// Compact, unlabeled SF Symbols toolbar (bootstrap §6): Outline | New, Open, Print | Undo, Redo.
/// No Save button: documents autosave.
@MainActor
enum MainToolbar {
    static func make() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "CartillaMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = Delegate.shared
        return toolbar
    }

    struct Item {
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
        let action: Selector
    }

    static let items: [Item] = [
        Item(
            id: .init("outline"), label: String(localized: "Outline"), symbol: "sidebar.left",
            action: #selector(DocumentWindowController.toggleOutline(_:))),
        Item(
            id: .init("new"), label: String(localized: "New"), symbol: "square.and.pencil",
            action: #selector(NSDocumentController.newDocument(_:))),
        Item(
            id: .init("open"), label: String(localized: "Open"), symbol: "folder",
            action: #selector(NSDocumentController.openDocument(_:))),
        Item(
            id: .init("print"), label: String(localized: "Print"), symbol: "printer",
            action: #selector(NSDocument.printDocument(_:))),
        Item(
            id: .init("undo"), label: String(localized: "Undo"), symbol: "arrow.uturn.backward",
            action: Selector(("undo:"))),
        Item(
            id: .init("redo"), label: String(localized: "Redo"), symbol: "arrow.uturn.forward",
            action: Selector(("redo:"))),
    ]

    @MainActor final class Delegate: NSObject, NSToolbarDelegate {
        static let shared = Delegate()

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [items[0].id, .space, items[1].id, items[2].id, items[3].id, .space, items[4].id, items[5].id]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            items.map(\.id) + [.space, .flexibleSpace]
        }

        func toolbar(
            _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool
        ) -> NSToolbarItem? {
            guard let spec = items.first(where: { $0.id == id }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = spec.label
            item.paletteLabel = spec.label
            item.toolTip = spec.label
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            item.action = spec.action
            item.isBordered = true
            return item
        }
    }
}
