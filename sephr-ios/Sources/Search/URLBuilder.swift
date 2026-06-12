import Foundation

/// Turns search-bar text into a destination: a direct URL when the text
/// looks like one, otherwise a query against the configured engine.
enum URLBuilder {

    enum Engine: String, CaseIterable, Identifiable {
        case google, duckduckgo, bing, kagi
        var id: String { rawValue }

        var label: String {
            switch self {
            case .google:     "Google"
            case .duckduckgo: "DuckDuckGo"
            case .bing:       "Bing"
            case .kagi:       "Kagi"
            }
        }

        func searchURL(for query: String) -> URL? {
            let escaped = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? query
            let template = switch self {
            case .google:     "https://www.google.com/search?q="
            case .duckduckgo: "https://duckduckgo.com/?q="
            case .bing:       "https://www.bing.com/search?q="
            case .kagi:       "https://kagi.com/search?q="
            }
            return URL(string: template + escaped)
        }
    }

    static var engine: Engine {
        get {
            Engine(rawValue: UserDefaults.standard
                .string(forKey: "searchEngine") ?? "") ?? .google
        }
        set { UserDefaults.standard.set(newValue.rawValue,
                                        forKey: "searchEngine") }
    }

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Explicit scheme → take it as-is.
        if trimmed.lowercased().hasPrefix("http://")
            || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }

        // Bare host or host/path: one token, contains a dot, no spaces —
        // or localhost with a port.
        let isHostLike = !trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.hasPrefix("localhost"))
        if isHostLike, let url = URL(string: "https://" + trimmed),
           url.host() != nil {
            return url
        }

        return engine.searchURL(for: trimmed)
    }
}
