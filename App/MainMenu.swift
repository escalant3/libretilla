import AppKit
import LibretillaDocx

/// Builds the standard macOS menu bar in code: AppKit's conventional items plus Libretilla's
/// Insert (M3) and Format (M2) menus.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(insertMenu()))
        main.addItem(submenu(formatMenu()))
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
        let menu = NSMenu(title: "Libretilla")
        menu.addItem(
            item(
                String(localized: "About Libretilla"),
                #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(Updater.menuItem())
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide Libretilla"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            item(
                String(localized: "Hide Others"),
                #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Libretilla"), #selector(NSApplication.terminate(_:)), "q"))
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
            item(String(localized: "Restore Original…"), #selector(LibretillaDocument.restoreOriginal(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Export as PDF…"), #selector(LibretillaDocument.exportPDF(_:))))
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
        let replace = item(
            String(localized: "Find and Replace…"), #selector(NSTextView.performTextFinderAction(_:)), "f",
            [.command, .option])
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        find.addItem(replace)
        let useSelection = item(
            String(localized: "Use Selection for Find"), #selector(NSTextView.performFindPanelAction(_:)), "e")
        useSelection.tag = Int(NSFindPanelAction.setFindString.rawValue)
        find.addItem(useSelection)
        find.addItem(
            item(String(localized: "Jump to Selection"), #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j"))
        let findItemParent = NSMenuItem(title: find.title, action: nil, keyEquivalent: "")
        findItemParent.submenu = find
        menu.addItem(findItemParent)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(
            item(
                String(localized: "Show Outline"), #selector(DocumentWindowController.toggleOutline(_:)), "s",
                [.command, .control]))
        menu.addItem(
            item(
                String(localized: "Hide Format Bar"), #selector(DocumentWindowController.toggleFormatBar(_:)), "b",
                [.command, .option]))
        menu.addItem(item(String(localized: "Show Ruler"), #selector(NSText.toggleRuler(_:)), "r"))
        menu.addItem(
            item(String(localized: "Show Page Edges"), #selector(DocumentWindowController.togglePageEdges(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Zoom to Fit"), #selector(EditorViewController.zoomToFit(_:))))
        menu.addItem(item(String(localized: "Actual Size"), #selector(EditorViewController.zoomToActualSize(_:)), "0"))
        menu.addItem(item(String(localized: "Zoom In"), #selector(EditorViewController.zoomIn(_:)), "+"))
        // ⌘= zooms in too, without Shift (as in browsers).
        let zoomInEquals = item(String(localized: "Zoom In"), #selector(EditorViewController.zoomIn(_:)), "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(item(String(localized: "Zoom Out"), #selector(EditorViewController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                [.command, .control]))
        return menu
    }

    // MARK: Format

    private static func insertMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Insert"))
        menu.addItem(item(String(localized: "Table…"), #selector(EditorViewController.insertTable(_:))))
        menu.addItem(item(String(localized: "Image…"), #selector(EditorViewController.insertImage(_:))))
        menu.addItem(item(String(localized: "Link…"), #selector(EditorViewController.editLink(_:)), "k"))
        menu.addItem(item(String(localized: "Page Break"), #selector(EditorViewController.insertPageBreak(_:)), "\r"))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Format"))
        menu.addItem(submenuItem(fontMenu()))
        menu.addItem(submenuItem(textMenu()))
        menu.addItem(submenuItem(styleMenu()))
        menu.addItem(submenuItem(listMenu()))
        menu.addItem(item(String(localized: "Edit Table…"), #selector(EditorViewController.editTable(_:))))
        menu.addItem(
            item(String(localized: "Header and Footer…"), #selector(EditorViewController.editHeaderAndFooter(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Clear Formatting"), #selector(EditorViewController.clearFormatting(_:)), "\\"))
        return menu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func fontMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Font"))
        menu.addItem(item(String(localized: "Show Fonts"), #selector(NSFontManager.orderFrontFontPanel(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bold"), #selector(EditorViewController.toggleBold(_:)), "b"))
        menu.addItem(item(String(localized: "Italic"), #selector(EditorViewController.toggleItalic(_:)), "i"))
        menu.addItem(item(String(localized: "Underline"), #selector(EditorViewController.toggleUnderline(_:)), "u"))
        menu.addItem(
            item(
                String(localized: "Strikethrough"), #selector(EditorViewController.toggleStrikethrough(_:)), "x",
                [.command, .shift]))
        menu.addItem(.separator())
        // ⇧⌘> / ⇧⌘<, as in Google Docs (⌘+ / ⌘− zoom: View menu).
        menu.addItem(item(String(localized: "Bigger"), #selector(EditorViewController.increaseFontSize(_:)), ">"))
        menu.addItem(item(String(localized: "Smaller"), #selector(EditorViewController.decreaseFontSize(_:)), "<"))
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Superscript"), #selector(EditorViewController.toggleSuperscript(_:)), "+",
                [.command, .control]))
        menu.addItem(
            item(
                String(localized: "Subscript"), #selector(EditorViewController.toggleSubscript(_:)), "-",
                [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Show Colors"), #selector(NSApplication.orderFrontColorPanel(_:)), "c",
                [.command, .shift]))
        menu.addItem(
            item(String(localized: "Automatic Text Color"), #selector(EditorViewController.applyAutomaticTextColor(_:)))
        )
        let highlight = NSMenu(title: String(localized: "Highlight"))
        highlight.addItem(item(String(localized: "No Highlight"), #selector(EditorViewController.applyHighlight(_:))))
        for (name, title) in FormatBarViewController.highlights {
            let i = item(title, #selector(EditorViewController.applyHighlight(_:)))
            i.representedObject = name
            i.image = FormatBarViewController.swatch(AttributedStringBridge.highlightColor(name))
            highlight.addItem(i)
        }
        menu.addItem(submenuItem(highlight))
        return menu
    }

    static func textMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Text"))
        let alignments: [(String, String)] = [
            (String(localized: "Align Left"), "{"), (String(localized: "Center"), "|"),
            (String(localized: "Align Right"), "}"), (String(localized: "Justify"), ""),
        ]
        for (i, (title, key)) in alignments.enumerated() {
            let a = item(title, #selector(EditorViewController.applyAlignment(_:)), key)
            a.tag = i
            menu.addItem(a)
        }
        menu.addItem(.separator())
        let spacing = NSMenu(title: String(localized: "Spacing"))
        for i in spacingItems() { spacing.addItem(i) }
        menu.addItem(submenuItem(spacing))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Increase Indent"), #selector(EditorViewController.increaseIndent(_:)), "]"))
        menu.addItem(
            item(String(localized: "Decrease Indent"), #selector(EditorViewController.decreaseIndent(_:)), "["))
        return menu
    }

    /// Line spacing presets and paragraph spacing toggles (Format ▸ Text ▸ Spacing and the format bar).
    static func spacingItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (title, value) in [("1", 1.0), ("1.15", 1.15), ("1.5", 1.5), ("2", 2.0)] {
            let i = item(
                String(localized: "Line Spacing \(title)"), #selector(EditorViewController.applyLineSpacing(_:)))
            i.representedObject = value
            items.append(i)
        }
        items.append(.separator())
        items.append(
            item(String(localized: "Add Space Before Paragraph"), #selector(EditorViewController.toggleSpaceBefore(_:)))
        )
        items.append(
            item(String(localized: "Add Space After Paragraph"), #selector(EditorViewController.toggleSpaceAfter(_:))))
        return items
    }

    static func styleMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Style"))
        for (i, (name, title)) in StyleChoice.standard.enumerated() {
            // ⌥⌘0 Normal, ⌥⌘1…6 headings, as in Google Docs.
            let key: String =
                switch i {
                case 0: "0"
                case 3...8: String(i - 2)
                default: ""
                }
            let s = item(title, #selector(EditorViewController.applyParagraphStyle(_:)), key, [.command, .option])
            s.representedObject = StyleChoice.builtIn(name).key
            menu.addItem(s)
        }
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Update Style to Match Selection"),
                #selector(EditorViewController.updateStyleToMatchSelection(_:))))
        return menu
    }

    static func listMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "List"))
        menu.addItem(
            item(
                String(localized: "Bulleted List"), #selector(EditorViewController.toggleBulletedList(_:)), "8",
                [.command, .shift]))
        menu.addItem(
            item(
                String(localized: "Numbered List"), #selector(EditorViewController.toggleNumberedList(_:)), "7",
                [.command, .shift]))
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
