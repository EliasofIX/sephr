import AppKit

struct SephrSearchResult: Identifiable, Hashable {
    enum Kind: String { case url, search, history, bookmark, tab, space, action }

    let id = UUID()
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

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SephrSearchResult, rhs: SephrSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}
