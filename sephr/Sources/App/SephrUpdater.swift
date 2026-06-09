import Foundation

#if canImport(Sparkle)
import Sparkle

/// Private self-hosted update feed.
/// Feed URL configured in Info.plist → SUFeedURL
/// → https://updates.INTERNAL_DOMAIN/sephr/appcast.xml
final class SephrUpdater {
    private let controller: SPUStandardUpdaterController?

    init() {
        // Sparkle aggressively contacts the SUFeedURL at startup and pops
        // a modal "updater failed to start" alert if the feed can't be
        // reached. Dev / pre-release builds ship with a placeholder URL
        // (updates.example.com) — instantiate the controller only when a
        // real feed is configured so contributors aren't dismissing a
        // dialog on every launch.
        if Self.isFeedConfigured() {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil)
        } else {
            controller = nil
            NSLog("[sephr/updater] SUFeedURL is the placeholder " +
                  "(updates.example.com) — Sparkle disabled.")
        }
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private static func isFeedConfigured() -> Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL")
                as? String else { return false }
        let placeholder = feed.isEmpty
            || feed.contains("example.com")
            || feed.contains("INTERNAL_DOMAIN")
            || feed.contains("REPLACE")
        return !placeholder
    }
}

#else
// Sparkle not linked yet (e.g. CI before `pod install`). Provide a no-op
// stand-in with the same API so the rest of the app compiles.
final class SephrUpdater {
    init() {}
    func checkNow() {}
    var automaticallyChecksForUpdates: Bool = false
}
#endif
