import AppKit

@MainActor
final class SephrKeyboardShortcutMonitor {
    static let shared = SephrKeyboardShortcutMonitor()
    private var monitor: Any?

    private init() {}

    func register(in wc: SephrWindowController) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak wc] event in
            // NSEvent.addLocalMonitorForEvents fires on the main thread,
            // so MainActor.assumeIsolated is safe and gives us access to
            // the main-actor-isolated SephrTabModel/SephrSpaceManager APIs.
            MainActor.assumeIsolated {
                guard let wc else { return event }
                return Self.handle(event, wc: wc)
            }
        }
    }

    private static func handle(
        _ event: NSEvent,
        wc: SephrWindowController
    ) -> NSEvent? {

        // Fast path: nothing below this point fires without Command, and
        // local key monitors run synchronously on the main thread for
        // every keypress — including while the user types into a web
        // input. Short-circuit before doing the flag-set / character
        // resolution work for the 99% case.
        guard event.modifierFlags.contains(.command) else { return event }

        let cmd   = true
        let shift = event.modifierFlags.contains(.shift)
        let opt   = event.modifierFlags.contains(.option)
        let key   = event.charactersIgnoringModifiers ?? ""

        switch (cmd, shift, opt, key) {
        case (true, false, false, "q"):
            // Catch Cmd+Q upstream so the confirmation alert always
            // runs, even when Chromium's AppController has rewired the
            // shortcut on its end.
            SephrQuitController.shared.confirmQuit(nil); return nil
        case (true, false, false, "t"):
            SephrCommandBar.show(in: wc); return nil
        case (true, false, false, "w"):
            SephrTabModel.shared.closeActiveTab(); return nil
        case (true, true, false, "["):
            SephrTabModel.shared.previousTab(); return nil
        case (true, true, false, "]"):
            SephrTabModel.shared.nextTab(); return nil
        case (true, true, false, "s"):
            _ = SephrSpaceManager.shared.createSpace(name: "New Space")
            return nil
        case (true, false, false, "\\"):
            wc.sidebarView.toggleCompactMode(); return nil
        case (true, false, false, "/"):
            wc.sidebarView.toggleCollapse(); return nil
        case (true, false, false, "s"):
            // Cmd+S = toggle sidebar visibility. We intentionally swallow
            // the event so Chromium's "Save Page As" handler never gets
            // it — we also suppress the underlying feature via
            // `--disable-features=DownloadShelf,SavePageAsMHTML` and
            // `--save-page-as-mhtml=0` so the renderer can't surface
            // its own dialog either.
            wc.sidebarView.toggleCollapse(); return nil
        case (true, false, false, "g"):
            SephrTabModel.shared.groupSelectedTabs(); return nil
        case (true, false, true, "n"):
            LittleSephrWindow.show(); return nil
        case (true, false, true, "\u{f703}"):
            // ⌥⌘→ — next Space (Arc-style). Caught upstream here so it
            // wins over any Chromium "Select Next Tab" accelerator bound
            // to the same chord. The Spaces menu shows the glyph.
            SephrSpaceManager.shared.switchByOffset(1); return nil
        case (true, false, true, "\u{f702}"):
            // ⌥⌘← — previous Space.
            SephrSpaceManager.shared.switchByOffset(-1); return nil
        case (true, false, false, "r"):
            SephrTabModel.shared.activeTab()?.webView?.reload(); return nil
        case (true, false, false, "l"):
            SephrCommandBar.show(in: wc); return nil

        // Standard pasteboard shortcuts — we route these through the
        // AppKit responder chain ourselves because Chromium's
        // AppController hangs the menu's Edit > Paste / Copy / Cut /
        // Select All actions off its own Browser plumbing, which our
        // raw-WebContents embed never sets up. Without this, Cmd+V
        // (and friends) silently no-ops on web inputs even though the
        // `WebContentsViewCocoa` implements those selectors natively.
        // `sendAction(_:to: nil)` walks the responder chain from the
        // window's first responder, so an NSTextField inside the URL
        // bar still gets pasted into when it's focused — the page
        // input gets it when the WebContentsViewCocoa is focused.
        case (true, false, false, "v"):
            NSApp.sendAction(#selector(NSText.paste(_:)),
                             to: nil, from: nil); return nil
        case (true, false, false, "c"):
            NSApp.sendAction(#selector(NSText.copy(_:)),
                             to: nil, from: nil); return nil
        case (true, false, false, "x"):
            NSApp.sendAction(#selector(NSText.cut(_:)),
                             to: nil, from: nil); return nil
        case (true, false, false, "a"):
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)),
                             to: nil, from: nil); return nil
        case (true, false, false, "z"):
            NSApp.sendAction(#selector(UndoManager.undo),
                             to: nil, from: nil); return nil
        case (true, true, false, "z"):
            NSApp.sendAction(#selector(UndoManager.redo),
                             to: nil, from: nil); return nil
        case (true, true, false, "v"):
            // Paste as plain text → the WebContentsViewCocoa selector.
            NSApp.sendAction(Selector(("pasteAndMatchStyle:")),
                             to: nil, from: nil); return nil

        default:
            // Cmd+1..9 → switch Space
            if cmd, !shift, !opt, let n = Int(key), n >= 1, n <= 9 {
                let spaces = SephrSpaceManager.shared.spaces
                if n <= spaces.count {
                    SephrSpaceManager.shared.switchToSpace(spaces[n - 1])
                }
                return nil
            }
            return event
        }
    }
}
