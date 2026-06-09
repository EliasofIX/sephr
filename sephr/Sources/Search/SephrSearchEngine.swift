import Foundation

/// The four search engines Sephr ships with. `custom` reads its prefix
/// from `SephrPreferences.customSearchURL` so power users can point at
/// SearXNG, Kagi (with their API), or whatever they prefer.
enum SephrSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case brave
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google:     return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .brave:      return "Brave"
        case .custom:     return "Custom"
        }
    }

    /// URL prefix the encoded query is appended to. The `custom` case
    /// reads from preferences at call time; callers should go through
    /// `SephrSearchEngines.queryURL(for:)` rather than reading `prefix`
    /// directly.
    var prefix: String {
        switch self {
        case .google:     return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .brave:      return "https://search.brave.com/search?q="
        case .custom:     return SephrPreferences.customSearchURL
        }
    }
}

enum SephrSearchEngines {

    /// The currently selected engine, decoded from preferences. Falls
    /// back to DuckDuckGo when the stored ID is unrecognised (e.g.
    /// migrated from an earlier free-text setting).
    static var current: SephrSearchEngine {
        SephrSearchEngine(rawValue: SephrPreferences.searchEngineID)
            ?? .duckduckgo
    }

    /// Builds a navigable search URL for `query` using the current
    /// engine. Returns nil if the engine's prefix is empty (Custom is
    /// configured but the user hasn't pasted a URL yet) so callers can
    /// surface that as a UI hint rather than navigating to a bare host.
    static func queryURL(for query: String) -> String? {
        let prefix = current.prefix
        guard !prefix.isEmpty else { return nil }
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? ""
        return prefix + encoded
    }
}
