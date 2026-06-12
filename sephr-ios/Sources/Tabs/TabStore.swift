import Foundation
import Observation

/// The browsing model: ordered tabs, the active tab, and the archive.
/// Persists as JSON in Application Support; snapshots live next to it as
/// JPEGs keyed by tab id. Auto-archiving runs on launch and foreground —
/// tabs untouched past the configured horizon slide into the archive
/// rather than accumulating forever.
@Observable
final class TabStore {

    enum ArchiveHorizon: String, CaseIterable, Codable, Identifiable {
        case twelveHours, day, week, month, never
        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .twelveHours: 12 * 3600
            case .day:         24 * 3600
            case .week:        7 * 86400
            case .month:       30 * 86400
            case .never:       nil
            }
        }

        var label: String {
            switch self {
            case .twelveHours: "12 hours"
            case .day:         "24 hours"
            case .week:        "7 days"
            case .month:       "30 days"
            case .never:       "Never"
            }
        }
    }

    private(set) var tabs: [SephrTab] = []
    var activeTabID: UUID?

    var archiveHorizon: ArchiveHorizon {
        didSet { persist() }
    }

    /// Live (non-archived) tabs, newest first — the order the deck shows.
    var liveTabs: [SephrTab] {
        tabs.filter { !$0.isArchived }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.lastAccessedAt > b.lastAccessedAt
            }
    }

    var archivedTabs: [SephrTab] {
        tabs.filter(\.isArchived).sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var activeTab: SephrTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    private let storeURL: URL
    private var persistTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sephr", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("tabs.json")

        archiveHorizon = .day
        load()
        autoArchive()
    }

    // MARK: — Mutations

    @discardableResult
    func newTab(url: URL? = nil, incognito: Bool = false,
                activate: Bool = true) -> SephrTab {
        let tab = SephrTab(url: url, isIncognito: incognito)
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        persist()
        return tab
    }

    func activate(_ id: UUID) {
        guard var tab = tabs.first(where: { $0.id == id }) else { return }
        tab.lastAccessedAt = .now
        tab.isArchived = false
        update(tab)
        activeTabID = id
    }

    func update(_ tab: SephrTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[i] = tab
        persist()
    }

    func touch(_ id: UUID, url: URL? = nil, title: String? = nil) {
        guard var tab = tabs.first(where: { $0.id == id }) else { return }
        tab.lastAccessedAt = .now
        if let url { tab.url = url }
        if let title { tab.title = title }
        update(tab)
    }

    func archive(_ id: UUID) {
        guard var tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isArchived = true
        tab.isPinned = false
        update(tab)
        if activeTabID == id { activeTabID = liveTabs.first?.id }
        TabSnapshotCache.shared.evict(id)
    }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = liveTabs.first?.id }
        TabSnapshotCache.shared.remove(id)
        persist()
    }

    func togglePin(_ id: UUID) {
        guard var tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        update(tab)
    }

    func restore(_ id: UUID) {
        activate(id)
    }

    func clearArchive() {
        for tab in archivedTabs { TabSnapshotCache.shared.remove(tab.id) }
        tabs.removeAll(where: \.isArchived)
        persist()
    }

    /// Move every live tab past the horizon (and every incognito tab from
    /// a previous run) out of the deck.
    func autoArchive() {
        // Incognito tabs never survive a relaunch.
        tabs.removeAll { $0.isIncognito }

        guard let horizon = archiveHorizon.seconds else { return }
        let cutoff = Date.now.addingTimeInterval(-horizon)
        for var tab in tabs where !tab.isArchived && !tab.isPinned
            && tab.lastAccessedAt < cutoff {
            tab.isArchived = true
            tabs[tabs.firstIndex(where: { $0.id == tab.id })!] = tab
            TabSnapshotCache.shared.evict(tab.id)
        }
        if let active = activeTab, active.isArchived {
            activeTabID = liveTabs.first?.id
        }
        persist()
    }

    // MARK: — Persistence

    private struct Snapshot: Codable {
        var tabs: [SephrTab]
        var activeTabID: UUID?
        var archiveHorizon: ArchiveHorizon
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        tabs = snap.tabs
        activeTabID = snap.activeTabID
        archiveHorizon = snap.archiveHorizon
    }

    /// Debounced write — tab churn during browsing shouldn't hit the disk
    /// on every keystroke-sized mutation.
    private func persist() {
        persistTask?.cancel()
        let snap = Snapshot(tabs: tabs.filter { !$0.isIncognito },
                            activeTabID: activeTab?.isIncognito == true
                                ? nil : activeTabID,
                            archiveHorizon: archiveHorizon)
        let url = storeURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snap) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
