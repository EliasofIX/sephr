import AppKit

final class SephrTabFolder: Codable, Identifiable {
    let id: UUID
    var name: String
    var colorHex: String
    /// Optional so old folders persisted before icon support still
    /// decode cleanly; `resolvedSymbol` provides the runtime fallback.
    var symbolName: String?
    var spaceID: UUID
    var isExpanded: Bool

    init(id: UUID = UUID(),
         name: String,
         colorHex: String = "#7F8CFF",
         symbolName: String? = "folder",
         spaceID: UUID,
         isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.spaceID = spaceID
        self.isExpanded = isExpanded
    }

    var color: NSColor { NSColor(hexString: colorHex) ?? .systemIndigo }
    var resolvedSymbol: String { symbolName ?? "folder" }
}
