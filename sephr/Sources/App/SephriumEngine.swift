import Foundation
import CAL

final class SephriumEngine {
    static let shared = SephriumEngine()
    private var initialized = false

    private init() {}

    /// Registers a callback that fires on the UI thread once Chromium has
    /// reached `PostBrowserStart` — i.e. `g_browser_process` is alive,
    /// `ProfileManager` is up, and the initial profile has been loaded.
    /// Must be called BEFORE `initialize()` (which never returns under
    /// Phase 2 Option A). Pass `nil` to clear.
    func setUiBootCallback(_ callback: (() -> Void)?) {
        CALEngineBootstrap.setUiBootCallback(callback)
    }

    /// Boots Chromium inside this process. Calls `ChromeMain` via the CAL
    /// bridge — never returns until shutdown. The registered UI-boot
    /// callback fires once `g_browser_process` is ready.
    func initialize() {
        guard !initialized else { return }
        initialized = true
        // NOT `CALEngineBootstrap.initialize()` — that name collides with
        // ObjC's runtime `+initialize`, which fires on first message to
        // the class (e.g. our `setUiBootCallback:` call) and forwards
        // straight into ChromeMain before the embedder can register its
        // UI callback. `bootChromium` is the explicit entry point.
        CALEngineBootstrap.bootChromium()
    }

    /// Phase 2 Option A leaves this as a no-op (Chromium owns the pump),
    /// kept here so legacy callers don't break.
    func pumpOnce() {
        CALEngineBootstrap.pumpOnce()
    }
}
