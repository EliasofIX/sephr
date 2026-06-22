import AppKit

struct SephrSearchResult: Identifiable, Hashable {
    enum Kind: String { case url, search, history, bookmark, tab, space, action }

    /// Stable identity from kind + url + title — `let id = UUID()` would
    /// re-identify every row on every keystroke, forcing SwiftUI's
    /// ForEach to rebuild the whole results list instead of diffing it
    /// in place. With a stable id, rows that survive a query refinement
    /// stay mounted and their state (hover, fade, height) doesn't blink.
    var id: String { "\(kind.rawValue)|\(url ?? "")|\(title)" }
    let kind: Kind
    let title: String
    let subtitle: String
    let url: String?
    let favicon: NSImage?

    var systemIcon: String {
        switch kind {
        case .url:      return "link"
        case .search:   return "magnifyingglass"
        case .history:  return "clock"
        case .bookmark: return "bookmark"
        case .tab:      return "square.stack"
        case .space:    return "rectangle.3.group"
        case .action:   return "command"
        }
    }

    var typeLabel: String {
        switch kind {
        case .url:      return "URL"
        case .search:   return "Search"
        case .history:  return "History"
        case .bookmark: return "Bookmark"
        case .tab:      return "Tab"
        case .space:    return "Space"
        case .action:   return "Action"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(url)
        hasher.combine(title)
    }
    static func == (lhs: SephrSearchResult, rhs: SephrSearchResult) -> Bool {
        lhs.kind == rhs.kind && lhs.url == rhs.url && lhs.title == rhs.title
    }
}
