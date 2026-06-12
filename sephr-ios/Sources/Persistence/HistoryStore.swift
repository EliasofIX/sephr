import Foundation
import Observation

/// Browsing history — capped ring of visits, newest first, persisted as
/// JSON. Backs the search-bar suggestions. Incognito never records.
@Observable
final class HistoryStore {

    struct Visit: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var url: URL
        var title: String
        var date: Date = .now
    }

    private(set) var visits: [Visit] = []
    private let cap = 2000
    private let storeURL: URL
    private var persistTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sephr", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode([Visit].self, from: data) {
            visits = loaded
        }
    }

    func record(url: URL, title: String) {
        // Collapse consecutive duplicates (reload, fragment hops).
        if let last = visits.first, last.url == url {
            visits[0].title = title
            visits[0].date = .now
        } else {
            visits.insert(Visit(url: url, title: title), at: 0)
            if visits.count > cap { visits.removeLast(visits.count - cap) }
        }
        persist()
    }

    /// Prefix/substring match over titles and hosts for the search bar.
    func suggestions(for query: String, limit: Int = 5) -> [Visit] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Visit] = []
        for visit in visits {
            let host = visit.url.host() ?? ""
            guard visit.title.lowercased().contains(q)
                || host.lowercased().contains(q)
                || visit.url.absoluteString.lowercased().contains(q)
            else { continue }
            // One suggestion per host+path.
            let key = host + visit.url.path()
            guard seen.insert(key).inserted else { continue }
            out.append(visit)
            if out.count >= limit { break }
        }
        return out
    }

    func clear() {
        visits = []
        persist()
    }

    private func persist() {
        persistTask?.cancel()
        let snapshot = visits
        let url = storeURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
