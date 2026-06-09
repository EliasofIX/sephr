import AppKit

@main
enum SephrApp {
    /// We can NOT replace `NSApp.delegate` — Chromium installs its own
    /// `AppController` and `app_controller_mac.mm` has a CHECK_EQ enforcing
    /// it. Holding our window controller at file scope keeps it (and
    /// indirectly everything it owns: tabs, sidebar, AppDelegate's old
    /// responsibilities) alive across the run loop.
    nonisolated(unsafe) static var mainController: SephrWindowController?
    nonisolated(unsafe) static var updater: SephrUpdater?

    static func main() {
        SephriumEngine.shared.setUiBootCallback {
            func log(_ s: String) {
                if let d = (s + "\n").data(using: .utf8) {
                    FileHandle.standardError.write(d)
                }
            }
            log("[sephr] UI-boot callback firing")
            let app = NSApplication.shared
            // Activate without touching `app.delegate` — Chromium's own
            // AppController stays installed and keeps ProfileManager
            // happy. We just bring our window up alongside it.
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)

            let wc = SephrWindowController()
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            wc.window?.orderFrontRegardless()
            mainController = wc

            // Default-browser routing: register the external-URL handler now
            // that the window + tab model exist. This both wires future link
            // opens into Sephr tabs and flushes any URL the OS delivered
            // during a cold launch (which the CAL bridge buffered until now).
            SephrDefaultBrowser.shared.installURLHandler()

            // Auto-focus the URL field in the sidebar so the user can
            // type immediately on launch. Cmd-T still opens the floating
            // palette as a richer search interface.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                wc.sidebarView?.urlField.makeFirstResponder()
            }
            updater = SephrUpdater()
            updater?.automaticallyChecksForUpdates = true

            // Hijack Chromium's "Settings…" menu item so it opens our
            // native preferences window instead of chrome://settings.
            // Install once, then re-assert after a beat and on every
            // activation — Chromium re-templates its menu in a few edge
            // cases (profile load, full-screen entry).
            SephrSettingsController.shared.installMenuOverride()
            SephrQuitController.shared.installMenuOverride()
            SephrSpacesMenuController.shared.install()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    SephrSettingsController.shared.installMenuOverride()
                    SephrQuitController.shared.installMenuOverride()
                    SephrSpacesMenuController.shared.install()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    SephrSettingsController.shared.installMenuOverride()
                    SephrQuitController.shared.installMenuOverride()
                    SephrSpacesMenuController.shared.install()
                }
            }

            // Persist on quit. Chromium's AppController will send the
            // NSApplicationWillTerminate notification through its own
            // hooks; we just observe it here. The tab model coalesces
            // writes on a debounce — `flushPersist()` forces any pending
            // write to land before we tear the run loop down.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    SephrTabModel.shared.flushPersist()
                }
                SephrSessionStore.shared.flush()
            }

            log("[sephr] window count after wc.showWindow: \(app.windows.count)")
        }
        SephriumEngine.shared.initialize()  // → ChromeMain, never returns.
    }
}
