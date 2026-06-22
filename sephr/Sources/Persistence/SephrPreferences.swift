import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum SephrPreferences {

    @UserDefault(key: "sidebar.width", defaultValue: 240.0)
    static var sidebarWidth: CGFloat

    @UserDefault(key: "sidebar.compact", defaultValue: false)
    static var sidebarCompact: Bool

    @UserDefault(key: "sidebar.collapsed", defaultValue: false)
    static var sidebarCollapsed: Bool

    @UserDefault(key: "theme.mode", defaultValue: "system")
    static var themeMode: String

    @UserDefault(key: "tabs.archiveAfterDays", defaultValue: 7)
    static var archiveAfterDays: Int

    @UserDefault(key: "tabs.suspendAfterSeconds", defaultValue: 300)
    static var suspendAfterSeconds: Int

    /// Minutes a hidden tab keeps its live renderer before sleeping
    /// (WebContents destroyed; tab re-navigates on activation).
    /// 0 disables tab sleeping entirely.
    @UserDefault(key: "tabs.sleepAfterMinutes", defaultValue: 30)
    static var sleepAfterMinutes: Int

    @UserDefault(key: "privacy.blockAds", defaultValue: true)
    static var blockAds: Bool

    @UserDefault(key: "privacy.blockTrackers", defaultValue: true)
    static var blockTrackers: Bool

    @UserDefault(key: "search.engine",
                 defaultValue: "https://search.brave.com/search?q=")
    static var searchEngine: String

    /// Selected search engine identifier. One of the SephrSearchEngine
    /// raw values (`google`, `duckduckgo`, `brave`, `custom`). Stored
    /// separately from `searchEngine` (the resolved URL prefix) so the
    /// settings UI can show the right picker selection without having
    /// to reverse-engineer it from a URL string.
    @UserDefault(key: "search.engineID", defaultValue: "duckduckgo")
    static var searchEngineID: String

    /// User-supplied query-URL prefix when `searchEngineID == "custom"`.
    /// The user's query is URL-encoded and appended verbatim.
    @UserDefault(key: "search.customURL", defaultValue: "")
    static var customSearchURL: String

    /// Show the "Are you sure you want to quit?" dialog on Cmd+Q.
    /// Disabled by the "Always quit" choice in that dialog.
    @UserDefault(key: "quit.confirm", defaultValue: true)
    static var confirmOnQuit: Bool

    // MARK: — Peek (link preview) — surfaced in Settings ▸ Links.

    /// Open a Peek preview when a link is clicked with Shift held.
    @UserDefault(key: "peek.onShiftClick", defaultValue: true)
    static var peekOnShiftClick: Bool

    /// Open a Peek when clicking a link that points to another site.
    /// Only affects Favorites and Pinned tabs, like Arc.
    @UserDefault(key: "peek.onExternalLinks", defaultValue: true)
    static var peekOnExternalLinks: Bool

    /// Idle Peek windows close (archive) after this many hours.
    @UserDefault(key: "peek.archiveHours", defaultValue: 6)
    static var peekArchiveHours: Int

    /// Show a live preview popover when hovering a sidebar tab.
    @UserDefault(key: "peek.onSidebarHover", defaultValue: true)
    static var peekOnSidebarHover: Bool

    // MARK: — Profile card (Settings ▸ Profile).

    /// User-chosen display name shown on the profile card. Empty falls
    /// back to a suggested name at render time.
    @UserDefault(key: "profile.displayName", defaultValue: "")
    static var profileDisplayName: String

    /// The profile "character": an emoji / Unicode glyph, or an SF Symbol
    /// name prefixed `sf:` (see `SephrGlyph`). Empty shows a placeholder.
    @UserDefault(key: "profile.character", defaultValue: "")
    static var profileCharacter: String

    // MARK: — App icon (Settings ▸ Icon). Only index 0 ships today.

    @UserDefault(key: "appearance.appIcon", defaultValue: 0)
    static var appIconIndex: Int

    // MARK: — Developer Mode (URL-bar page-settings panel).

    /// When on, the URL-bar page-settings panel exposes a Developer
    /// Tools action for the active page. Read here and via the matching
    /// `@AppStorage("developer.mode")` key in `SephrPageSettingsPanel`.
    @UserDefault(key: "developer.mode", defaultValue: false)
    static var developerMode: Bool
}
