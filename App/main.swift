import AppKit

// Programmatic entry point (no storyboard / main nib).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.mainMenu = MainMenu.make()
    withExtendedLifetime(delegate) {
        app.run()
    }
}
