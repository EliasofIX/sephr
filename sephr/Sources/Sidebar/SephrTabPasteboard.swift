import AppKit

/// Shared pasteboard plumbing for in-sidebar tab drags. The dragged
/// payload is just the tab's UUID; the drop target looks the tab up via
/// `SephrTabModel.shared` so we never accidentally encode a stale snapshot.
enum SephrTabPasteboard {
    static let type = NSPasteboard.PasteboardType("com.sephr.tab")

    static func pasteboardItem(for tab: SephrTab) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: type)
        return item
    }

    /// Pulls the tab UUID out of a drag's pasteboard if one of our
    /// items is on it. Returns nil for foreign drags (URLs from
    /// Finder, text, etc.) so the drop target can refuse them.
    static func tabID(from pasteboard: NSPasteboard) -> UUID? {
        guard let s = pasteboard.string(forType: type) else { return nil }
        return UUID(uuidString: s)
    }
}
