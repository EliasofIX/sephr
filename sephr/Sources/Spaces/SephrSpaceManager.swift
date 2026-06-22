import AppKit
import CAL

// No SwiftUI / Combine consumers — every observer reacts to
// `.sephrSpaceChanged` / `.sephrSpaceListChanged` notifications. The
// previous `@Published`s on `spaces` / `currentSpace` fired
// `objectWillChange` on every mutation with nobody subscribed, paying
// the publisher cost on the cold-launch path for nothing.
@MainActor
final class SephrSpaceManager {
    static let shared = SephrSpaceManager()

    private(set) var spaces: [SephrSpace] = []
    private(set) var currentSpace: SephrSpace

    private init() {
        let saved = SephrSessionStore.shared.loadSpaces()
        // Stricter Swift initialization rules: don't read `self.spaces`
        // before all stored properties are initialized. Compute the
        // resolved list in a local first.
        let resolved = saved.isEmpty ? [SephrSpace.defaultSpace()] : saved
        self.spaces = resolved
        self.currentSpace = resolved.first!
        // Persist on cold-bootstrap so the freshly-minted default
        // space's UUID survives the next launch. Without this, every
        // launch with no saved spaces mints a NEW default UUID and
        // every persisted tab (which carries the previous default's
        // spaceID) becomes an orphan that won't show up in the
        // sidebar — silently breaking tab persistence.
        if saved.isEmpty {
            persist()
        } else {
            bootstrapSidebarFavoritesIfNeeded()
        }
    }

    static let maxSidebarFavorites = 4

    /// Spaces pinned to the footer switcher — favorited ones, capped at
    /// four, with the active space always included.
    func footerSpaces() -> [SephrSpace] {
        var favs = spaces.filter(\.isFavorited)
        if favs.count > Self.maxSidebarFavorites {
            favs = Array(favs.prefix(Self.maxSidebarFavorites))
        }
        if !favs.contains(where: { $0.id == currentSpace.id }) {
            if favs.count >= Self.maxSidebarFavorites {
                favs.removeLast()
            }
            favs.insert(currentSpace, at: 0)
        }
        return favs
    }

    /// Toggle whether a space appears in the sidebar footer (max four).
    func setFavorite(_ space: SephrSpace, favorite: Bool) {
        guard let idx = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        if favorite {
            let count = spaces.filter(\.isFavorited).count
            if count >= Self.maxSidebarFavorites, !spaces[idx].isFavorited {
                if let drop = spaces.firstIndex(where: {
                    $0.isFavorited && $0.id != currentSpace.id
                }) ?? spaces.firstIndex(where: \.isFavorited) {
                    spaces[drop].isFavorited = false
                }
            }
            spaces[idx].isFavorited = true
        } else {
            spaces[idx].isFavorited = false
        }
        if currentSpace.id == space.id { currentSpace = spaces[idx] }
        persist()
        NotificationCenter.default.post(name: .sephrSpaceListChanged, object: nil)
    }

    func toggleFavorite(_ space: SephrSpace) {
        guard let idx = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        setFavorite(space, favorite: !spaces[idx].isFavorited)
    }

    /// First launch after the favorite field ships: pin the first four
    /// spaces so existing users don't get an empty footer.
    private func bootstrapSidebarFavoritesIfNeeded() {
        guard !spaces.contains(where: \.isFavorited) else { return }
        for i in spaces.indices where i < Self.maxSidebarFavorites {
            spaces[i].isFavorited = true
        }
        persist()
    }

    @discardableResult
    func createSpace(name: String,
                     symbolName: String = "circle.hexagongrid",
                     color: String = "#7F8CFF",
                     isolated: Bool = false) -> SephrSpace {
        let s = SephrSpace(
            id: UUID(),
            name: name,
            emoji: "",
            symbolName: symbolName,
            colorHex: color,
            useIsolatedProfile: isolated,
            backgroundImagePath: nil,
            createdAt: Date(),
            isFavorited: spaces.filter(\.isFavorited).count < Self.maxSidebarFavorites
        )
        spaces.append(s)
        persist()
        NotificationCenter.default.post(name: .sephrSpaceListChanged, object: nil)
        return s
    }

    /// Switch to the space at `offset` positions from the current one
    /// (positive = right, negative = left). Wraps at the ends so the
    /// swipe gesture in the sidebar feels continuous.
    func switchByOffset(_ offset: Int) {
        guard spaces.count > 1,
              let idx = spaces.firstIndex(of: currentSpace) else { return }
        let next = (idx + offset + spaces.count) % spaces.count
        switchToSpace(spaces[next])
    }

    func deleteSpace(_ space: SephrSpace) {
        if space.id == currentSpace.id {
            if let other = spaces.first(where: { $0.id != space.id }) {
                switchToSpace(other)
            } else {
                return    // never delete the last space
            }
        }
        SephrTabModel.shared.archiveTabs(in: space)
        spaces.removeAll { $0.id == space.id }
        if space.useIsolatedProfile {
            CALProfile.delete(withID: space.profileID)
        }
        persist()
        NotificationCenter.default.post(name: .sephrSpaceListChanged, object: nil)
    }

    func switchToSpace(_ space: SephrSpace) {
        guard space.id != currentSpace.id else { return }
        SephrTabModel.shared.freezeTabs(in: currentSpace)
        currentSpace = space
        SephrSpaceThemeEngine.shared.apply(space)
        SephrTabModel.shared.prepareSpace(space)
        NotificationCenter.default.post(name: .sephrSpaceChanged, object: space)
        persist()
    }

    func updateSpace(_ space: SephrSpace) {
        guard let idx = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[idx] = space
        if currentSpace.id == space.id { currentSpace = space }
        SephrSpaceThemeEngine.shared.apply(space)
        persist()
        NotificationCenter.default.post(name: .sephrSpaceListChanged, object: nil)
    }

    /// Reorder a space to a new slot in the list. Drives the Manage
    /// Spaces board's column drag. `newIndex` is interpreted against the
    /// list *after* the moved space is pulled out, so dropping a space
    /// onto a column to its right lands it after that column and onto a
    /// column to its left lands it before — which reads naturally during
    /// a drag. Persists the new order and posts `.sephrSpaceListChanged`
    /// so the sidebar switcher and the Spaces menu re-render.
    func moveSpace(_ space: SephrSpace, toIndex newIndex: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == space.id })
        else { return }
        var reordered = spaces
        let moved = reordered.remove(at: from)
        let dest = max(0, min(newIndex, reordered.count))
        reordered.insert(moved, at: dest)
        guard reordered.map(\.id) != spaces.map(\.id) else { return }
        spaces = reordered
        persist()
        NotificationCenter.default.post(name: .sephrSpaceListChanged, object: nil)
    }

    private func persist() {
        SephrSessionStore.shared.saveSpaces(spaces, currentID: currentSpace.id)
    }
}
