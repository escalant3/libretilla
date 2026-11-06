import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any document opens (files opened at launch are read before didFinishLaunching).
        ChipLabels.install()
        // UI tests only: start from the default settings (`-LibretillaUITestFreshDefaults YES`). Passing the
        // settings themselves as arguments would pin them, so Settings couldn't change them.
        if UserDefaults.standard.bool(forKey: "LibretillaUITestFreshDefaults") {
            for key in [
                Preferences.keepsPageLightKey, Preferences.rulerUnitsKey, Preferences.outlineShownKey,
                DocumentWindowController.showsPageEdgesKey, DocumentWindowController.formatBarHiddenKey,
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // UI tests only: run in Light or Dark Mode whatever the Mac is set to (`-LibretillaUITestAppearance Dark`).
        switch UserDefaults.standard.string(forKey: "LibretillaUITestAppearance") {
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Target 2–5 s of idle time before autosave (bootstrap §5.4; tuned in M1).
        NSDocumentController.shared.autosavingDelay = 3
        OriginalsStore.shared.prune()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
