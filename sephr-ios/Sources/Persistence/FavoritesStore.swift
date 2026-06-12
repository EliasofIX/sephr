import Foundation
import Observation

/// In-app favorites — the row of sites above the keyboard on the search
/// screen. Small, ordered, persisted as JSON.
@Observable
final class FavoritesStore {

    struct Favorite: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var url: URL
        var title: String

        /// Short label under the glyph: the bare host.
        var label: String {
            let host = url.host() ?? title
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    private(set) var favorites: [Favorite] = []
    private let storeURL: URL

    init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sephr", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = loaded
        }
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favorites.contains { $0.url.host() == url.host()
            && $0.url.path() == url.path() }
    }

    func toggle(url: URL, title: String) {
        if let i = favorites.firstIndex(where: { $0.url.host() == url.host()
            && $0.url.path() == url.path() }) {
            favorites.remove(at: i)
        } else {
            favorites.append(Favorite(url: url, title: title))
        }
        persist()
    }

    func remove(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
