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
            createdAt: Date()
        )
    }
}
