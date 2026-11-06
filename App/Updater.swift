import AppKit
import Sparkle

/// Sparkle's updater (docs/RELEASING.md): Libretilla ▸ Check for Updates…, and a daily check once the user
/// agrees (Sparkle asks on the second launch). The app is sandboxed with no network entitlement, so Sparkle's
/// Downloader and Installer XPC services do the work. Debug builds never start it, so UI tests never see its
/// dialogs; the menu item is then disabled.
@MainActor
enum Updater {
    static let controller: SPUStandardUpdaterController = {
        #if DEBUG
            let start = false
        #else
            let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    /// The menu item. The controller enables it only while a check can start.
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
