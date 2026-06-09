import AppKit
import SwiftUI

/// Hosts the DIGITAL CAVIAR settings view. Navigation is the SwiftUI
/// `TabView`'s own Liquid Glass tab bar (see `SephrSettingsView`), so this
/// controller just owns the window and the wiring that hijacks Chromium's
/// "Settings…" menu item to open this window instead of the bundled
/// `chrome://settings` UI.
@MainActor
final class SephrSettingsController: NSObject, NSWindowDelegate {

    static let shared = SephrSettingsController()

    private var window: NSWindow?

    /// Bring the settings window forward, creating it lazily.
    @objc func showSettings(_ sender: Any?) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SephrSettingsView())
        host.view.frame = NSRect(x: 0, y: 0, width: 760, height: 720)

        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView]
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        // Non-opaque + clear background so the SwiftUI behind-window
        // VisualEffectBackground blurs the desktop through the window, and
        // the Liquid Glass tab bar floats over it.
        w.isOpaque = false
        w.backgroundColor = .clear
        w.setContentSize(NSSize(width: 720, height: 720))
        w.minSize = NSSize(width: 620, height: 520)
        w.center()
        w.delegate = self
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: — Chromium menu hijack

    /// Rebinds every Settings / Preferences item NSApp's main menu carries
    /// to our handler. Chromium installs its own AppController with a
    /// `chrome://settings` action; calling this AFTER that install rewrites
    /// the target so Cmd+, opens our native UI.
    func installMenuOverride() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            rebindSettingsItems(in: top.submenu)
        }
    }

    private func rebindSettingsItems(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            let t = item.title.lowercased()
            if t.contains("settings") || t.contains("preferences") {
                item.target = self
                item.action = #selector(showSettings(_:))
                item.keyEquivalent = ","
                item.keyEquivalentModifierMask = .command
            }
            rebindSettingsItems(in: item.submenu)
        }
    }
}
