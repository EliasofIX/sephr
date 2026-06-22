import Foundation
import CAL

/// Built-in content blocking via uBlock Origin (component extension).
enum SephrContentBlocking {

    /// uBlock Origin extension id — same as the public Chrome Web Store build.
    static let uBlockOriginID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    /// Sync `SephrPreferences.blockAds` to the bundled uBlock Origin
    /// extension for `profileID` (defaults to the active space).
    @MainActor
    static func applyPreference(profileID: String? = nil) {
        let pid = profileID ?? SephrSpaceManager.shared.currentSpace.profileID
        CALExtensions.sharedInstance(forProfile: pid)
            .setEnabled(uBlockOriginID, enabled: SephrPreferences.blockAds)
    }
}
