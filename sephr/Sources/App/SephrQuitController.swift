import AppKit

/// Catches every path that would terminate Sephr (menu "Quit Sephr…",
/// Cmd+Q) and routes it through a Dia-style confirmation alert. The
/// "Always quit" choice persists `SephrPreferences.confirmOnQuit = false`
/// so power users can opt out forever.
///
/// Why menu hijack + keyboard monitor? Chromium installs its own
/// AppController as NSApp.delegate (we can't replace it without tripping
/// a CHECK_EQ in app_controller_mac.mm), so the canonical
/// `applicationShouldTerminate(_:)` hook isn't ours to override. We catch
/// the quit gesture *upstream* — at the menu item and at the local key
/// event monitor — and call `NSApp.terminate(_:)` ourselves only after
/// the user confirms.
@MainActor
final class SephrQuitController: NSObject {

    static let shared = SephrQuitController()

    /// Action target for the rebound menu item AND the keyboard
    /// shortcut. Surfaces the alert; if the user opts to quit (or
    /// confirmation is disabled), terminates the app for real.
    @objc func confirmQuit(_ sender: Any?) {
        guard SephrPreferences.confirmOnQuit else {
            actuallyQuit()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to quit Sephr?"
        alert.informativeText = "You may lose unsaved work in your tabs."
        alert.alertStyle = .warning

        // NSAlert adds buttons right-to-left starting from the default
        // (first added). To match Dia's "Always quit | Cancel | Quit"
        // layout, that means:
        //   1st  → Quit         (rightmost, default, Return)
        //   2nd  → Cancel       (middle, ESC)
        //   3rd  → Always quit  (leftmost)
        let quitBtn = alert.addButton(withTitle: "Quit")
        quitBtn.keyEquivalent = "\r"
        let cancelBtn = alert.addButton(withTitle: "Cancel")
        cancelBtn.keyEquivalent = "\u{1b}"
        _ = alert.addButton(withTitle: "Always quit")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            actuallyQuit()
        case .alertThirdButtonReturn:
            SephrPreferences.confirmOnQuit = false
            actuallyQuit()
        default:
            break  // Cancel → stay
        }
    }

    /// Persist + tear down. The polite path — `NSApp.terminate(_:)` —
    /// is forwarded to Chromium's AppController, which implements
    /// `applicationShouldTerminate(_:)` by waiting for a Browser /
    /// TabStripModel to drain. We don't have either, so the polite
    /// path hangs forever. We try it anyway (so Chromium's atexit
    /// handlers run), but a 1-second watchdog force-exits the process
    /// if the polite path doesn't return — that's why "Quit" was
    /// previously a no-op.
    private func actuallyQuit() {
        // Force any debounced session-write to land before we tear the
        // run loop out from under it. Without this, the user's most
        // recent activate/navigate (which only marks the model dirty)
        // would not reach disk.
        SephrTabModel.shared.flushPersist()
        SephrSessionStore.shared.flush()
        // Fire willTerminateNotification explicitly so any code
        // subscribed for cleanup (session store, etc.) runs before we
        // tear out the run loop from under it.
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApp)
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Chromium's AppController returned .terminateLater and is
            // still waiting on a Browser instance we never created.
            // Force the issue.
            exit(0)
        }
    }

    /// Walks NSApp.mainMenu and rebinds every item whose action is the
    /// canonical `NSApplication.terminate(_:)` selector to our handler.
    /// Chromium's AppController installs that selector during ChromeMain;
    /// we re-rebind on app activation in case it re-templates the menu.
    func installMenuOverride() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            rebindQuitItems(in: top.submenu)
        }
    }

    private func rebindQuitItems(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if item.action == #selector(NSApplication.terminate(_:)) {
                item.target = self
                item.action = #selector(confirmQuit(_:))
                if item.keyEquivalent.isEmpty {
                    item.keyEquivalent = "q"
                    item.keyEquivalentModifierMask = .command
                }
            }
            rebindQuitItems(in: item.submenu)
        }
    }
}
