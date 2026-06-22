import AppKit

struct SephrSpace: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    /// Legacy. Spaces created before the SF Symbol switch carry an
    /// emoji here; new spaces leave it empty and rely on `symbolName`.
    /// Kept on the model so old `spaces.json` files still decode.
    var emoji: String
    /// SF Symbol name (e.g. `globe.americas`, `briefcase`). Optional
    /// for backwards-compat with `spaces.json` files written before
    /// this field existed — `resolvedSymbol` provides a fallback.
    var symbolName: String?
    var colorHex: String
    var useIsolatedProfile: Bool
    var backgroundImagePath: String?
    var createdAt: Date
    /// Pinned to the sidebar footer switcher (max 4 across all spaces).
    var isFavorited: Bool

    var color: NSColor {
        NSColor(hexString: colorHex) ?? .systemIndigo
    }

    /// SF Symbol name to render in the sidebar — falls back to a
    /// neutral default when the space was migrated from the old
    /// emoji-only schema.
    var resolvedSymbol: String { symbolName ?? "circle.hexagongrid" }

    /// Isolated spaces get their own CALProfile (separate cookies, storage,
    /// and cache). Non-isolated spaces share Chromium's "Default" profile
    /// (capital D — Chromium's auto-created profile is named this and
    /// registers it in Local State; using lowercase makes ProfileManager
    /// register a SEPARATE profile that bypasses the Network Service
    /// configuration the default one gets).
    var profileID: String {
        useIsolatedProfile ? "space-\(id.uuidString)" : "Default"
    }

    static func defaultSpace() -> SephrSpace {
        SephrSpace(
            id: UUID(),
            name: "Personal",
            emoji: "",
            symbolName: "circle.hexagongrid",
            colorHex: "#7F8CFF",
            useIsolatedProfile: false,
            backgroundImagePath: nil,
            createdAt: Date(),
            isFavorited: true
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, symbolName, colorHex, useIsolatedProfile
        case backgroundImagePath, createdAt, isFavorited
    }

    init(id: UUID,
         name: String,
         emoji: String = "",
         symbolName: String? = nil,
         colorHex: String,
         useIsolatedProfile: Bool,
         backgroundImagePath: String?,
         createdAt: Date,
         isFavorited: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.useIsolatedProfile = useIsolatedProfile
        self.backgroundImagePath = backgroundImagePath
        self.createdAt = createdAt
        self.isFavorited = isFavorited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        useIsolatedProfile = try c.decode(Bool.self, forKey: .useIsolatedProfile)
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited) ?? false
    }
}
