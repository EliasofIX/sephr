import AppKit
import CAL

/// Sephr's "default web browser" integration.
///
/// Two halves:
///   1. **Routing in** — when Sephr is the system default browser, the OS
///      hands every external link open (a click in Mail/Slack/Finder, a
///      Handoff hand-off, or the URL that cold-launched the app) to
///      Chromium's `AppController`. The CAL bridge intercepts that at its
///      single chokepoint (`-openUrlsReplacingNTP:` →
///      `sephr::MaybeRouteExternalUrl`) and forwards the URL here instead of
///      letting Chromium spawn a native window. `installURLHandler()` turns
///      each forwarded URL into a real Sephr tab.
///   2. **Becoming default** — `isDefault` / `setAsDefault` drive the system
///      http(s) handler registration so the user can make Sephr their
///      default with one click (and Settings can show the current state).
///
/// Not `@MainActor` so `installURLHandler()` can be called from the UI-boot
/// path without isolation ceremony; the bridge fires its callback on the UI
/// thread and we hop onto the main actor explicitly to touch the tab model.
final class SephrDefaultBrowser {
    static let shared = SephrDefaultBrowser()

    /// Cached `isDefault` answer. Filled lazily on first read; invalidated
    /// when the user runs `setAsDefault(...)` here, when the app comes back
    /// to the foreground (the handler may have been changed elsewhere
    /// while we were backgrounded), and whenever NSWorkspace itself fires
    /// `didChangeDefaultApplications`. The probe itself is a synchronous
    /// Launch Services XPC round-trip; without the cache it ran twice per
    /// open of the Settings General tab (the @State init plus onAppear).
    private var _cachedIsDefault: Bool?

    private init() {
        let nc = NotificationCenter.default
        let invalidate: @Sendable (Notification) -> Void = { [weak self] _ in
            self?._cachedIsDefault = nil
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                       object: nil, queue: .main, using: invalidate)
        // Pre-macOS-13 fallback path is .didChangeDefaultApplications via
        // the workspace center; harmless on newer systems.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main, using: invalidate)
    }

    // MARK: — Routing external opens into tabs

    /// Register the handler that receives external URL opens. Call from
    /// UI-boot AFTER the main window and tab model exist, so routed URLs land
    /// in a ready space. Any URL the OS delivered before this point (the
    /// cold-launch race — the launch URL arrives before our UI is up) was
    /// buffered on the Chromium side and is flushed to us synchronously the
    /// moment we register.
    func installURLHandler() {
        CALEngineBootstrap.setOpenExternalURLCallback { urlString in
            // The bridge fires on the UI (main) thread; assumeIsolated lets
            // us reach the @MainActor tab model without a hop that could
            // reorder rapid multi-URL opens.
            MainActor.assumeIsolated {
                SephrDefaultBrowser.shared.open(urlString)
            }
        }
    }

    @MainActor
    private func open(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let space = SephrSpaceManager.shared.currentSpace
        SephrTabModel.shared.newTab(in: space, url: trimmed)

        // The open came from another app — pull Sephr to the front.
        NSApp.activate(ignoringOtherApps: true)
        if let window = SephrApp.mainController?.window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // MARK: — Default-browser status

    /// True when Sephr is the registered system handler for https — the
    /// canonical "default web browser" signal on macOS. Cached; see
    /// `_cachedIsDefault` for the invalidation triggers.
    var isDefault: Bool {
        if let cached = _cachedIsDefault { return cached }
        guard let probe = URL(string: "https://sephr.app/"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { _cachedIsDefault = false; return false }
        let result = handler.resolvingSymlinksInPath().path
                  == Bundle.main.bundleURL.resolvingSymlinksInPath().path
        _cachedIsDefault = result
        return result
    }

    /// Ask the system to make Sephr the default for http + https. macOS
    /// surfaces its own "Use Sephr / Keep current" confirmation the first
    /// time; the completion reports whether both schemes were claimed. Runs
    /// on the main queue.
    func setAsDefault(completion: ((Bool) -> Void)? = nil) {
        let appURL = Bundle.main.bundleURL
        let group = DispatchGroup()
        var ok = true
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(
                at: appURL, toOpenURLsWithScheme: scheme
            ) { error in
                if error != nil { ok = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?._cachedIsDefault = nil
            completion?(ok)
        }
    }
}
