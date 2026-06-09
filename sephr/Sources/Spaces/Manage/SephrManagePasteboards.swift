import AppKit

/// Drag payload for moving a whole folder between spaces on the Manage
/// Spaces board. Mirrors `SephrTabPasteboard` — the payload is just the
/// folder's UUID; the drop target resolves it through `SephrTabModel` so
/// we never carry a stale snapshot.
enum SephrFolderPasteboard {
    static let type = NSPasteboard.PasteboardType("com.sephr.folder")

    static func pasteboardItem(for folder: SephrTabFolder) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(folder.id.uuidString, forType: type)
        return item
    }

    static func folderID(from pasteboard: NSPasteboard) -> UUID? {
        guard let s = pasteboard.string(forType: type) else { return nil }
        return UUID(uuidString: s)
    }
}

/// Drag payload for reordering whole spaces (columns) on the Manage
/// Spaces board. Carries the space's UUID; the drop target resolves it
/// through `SephrSpaceManager`.
enum SephrSpacePasteboard {
    static let type = NSPasteboard.PasteboardType("com.sephr.space")

    static func pasteboardItem(for space: SephrSpace) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(space.id.uuidString, forType: type)
        return item
    }

    static func spaceID(from pasteboard: NSPasteboard) -> UUID? {
        guard let s = pasteboard.string(forType: type) else { return nil }
        return UUID(uuidString: s)
    }
}
