import Foundation

/// Sections in the Arc-style library overlay — a minimal left rail with
/// Notes, Downloads, Archived Tabs, and the Manage Spaces board.
enum SephrLibrarySection: String, CaseIterable, Identifiable {
    case notes
    case downloads
    case archived
    case spaces

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notes:     return "Notes"
        case .downloads: return "Downloads"
        case .archived:  return "Archive"
        case .spaces:    return "Spaces"
        }
    }

    var systemIcon: String {
        switch self {
        case .notes:     return "square.and.pencil"
        case .downloads: return "arrow.down.circle"
        case .archived:  return "archivebox"
        case .spaces:    return "square.on.square"
        }
    }
}
