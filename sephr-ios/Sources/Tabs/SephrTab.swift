import Foundation

/// One browsing tab. Pure metadata — the live WKWebView (if any) lives in
/// `WebViewPool`, keyed by `id`. A tab with no live web view costs nothing
/// but this struct and a snapshot JPEG on disk.
struct SephrTab: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL?
    var title: String
    var createdAt: Date
    var lastAccessedAt: Date
    var isArchived: Bool
    var isPinned: Bool
    var isIncognito: Bool

    init(id: UUID = UUID(),
         url: URL? = nil,
         title: String = "",
         createdAt: Date = .now,
         lastAccessedAt: Date = .now,
         isArchived: Bool = false,
         isPinned: Bool = false,
         isIncognito: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.isIncognito = isIncognito
    }

    /// Display title: page title, else host, else a placeholder.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return "New Tab"
    }
}
