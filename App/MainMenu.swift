import AppKit

/// Builds the standard macOS menu bar in code. M0 only wires the conventional
/// items AppKit already implements; Format/Insert menus arrive in M2/M3.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Cartilla")
        menu.addItem(
            item(
                String(localized: "About Cartilla"),
                #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide Cartilla"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            item(
                String(localized: "Hide Others"),
                #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Cartilla"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item(String(localized: "New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.addItem(
            item(
                String(localized: "Clear Menu"),
                #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: recent.title, action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Save"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(
            item(String(localized: "Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Rename…"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Move To…"), #selector(NSDocument.move(_:))))
        menu.addItem(
            item(String(localized: "Revert To Saved"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(
            item(String(localized: "Browse All Versions…"), #selector(NSDocument.browseVersions(_:))))
        menu.addItem(
            item(String(localized: "Restore Original…"), #selector(CartillaDocument.restoreOriginal(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Page Setup…"), #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        menu.addItem(item(String(localized: "Print…"), #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: String(localized: "Find"))
        let findItem = item(String(localized: "Find…"), #selector(NSTextView.performFindPanelAction(_:)), "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        find.addItem(findItem)
        let findNext = item(String(localized: "Find Next"), #selector(NSTextView.performFindPanelAction(_:)), "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        find.addItem(findNext)
        let findPrev = item(
            String(localized: "Find Previous"), #selector(NSTextView.performFindPanelAction(_:)), "g",
            [.command, .shift])
        findPrev.tag = Int(NSFindPanelAction.previous.rawValue)
        find.addItem(findPrev)
        let findItemParent = NSMenuItem(title: find.title, action: nil, keyEquivalent: "")
        findItemParent.submenu = find
        menu.addItem(findItemParent)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(
            item(
                String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
