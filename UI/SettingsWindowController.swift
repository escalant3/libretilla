import AppKit
import SwiftUI

/// Libretilla ▸ Settings… (⌘,): a few app-wide choices. Changes apply to open windows at once.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel(String(localized: "Settings"))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.setContentSize(hosting.view.fittingSize)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        if let window, !window.isVisible, let screen = NSApp.mainWindow?.screen ?? NSScreen.main {
            // On the screen of the window being worked in (a new window's own screen can be any display),
            // centred across and a little above the middle, like `center()`.
            let area = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(
                NSPoint(x: area.midX - size.width / 2, y: area.minY + (area.height - size.height) * 2 / 3))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.keepsPageLightKey) private var keepsPageLight = false
    @AppStorage(DocumentWindowController.showsPageEdgesKey) private var showsPageEdges = false
    @AppStorage(DocumentWindowController.formatBarHiddenKey) private var formatBarHidden = false
    @AppStorage(Preferences.rulerUnitsKey) private var rulerUnit = Preferences.RulerUnit.localeDefault.rawValue

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Page in Dark Mode"), selection: $keepsPageLight) {
                    Text(String(localized: "Dark")).tag(false)
                    Text(String(localized: "Light, as printed")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("pageInDarkMode")
                Toggle(String(localized: "Show page edges"), isOn: $showsPageEdges)
                    .accessibilityIdentifier("showPageEdges")
                Toggle(
                    String(localized: "Show format bar"),
                    isOn: Binding(get: { !formatBarHidden }, set: { formatBarHidden = !$0 })
                )
                .accessibilityIdentifier("showFormatBar")
            }
            Section {
                Picker(String(localized: "Ruler units"), selection: $rulerUnit) {
                    ForEach(Preferences.RulerUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                // Segmented, not a menu: SwiftUI's menu picker exposes no action to VoiceOver (accessibility audit).
                .pickerStyle(.segmented)
                .accessibilityIdentifier("rulerUnits")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
