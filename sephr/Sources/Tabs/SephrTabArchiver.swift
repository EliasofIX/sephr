import Foundation

/// Background task that compacts the session store and evicts archived tabs
/// that have not been accessed in more than `maxAgeDays`.
@MainActor
final class SephrTabArchiver {
    static let shared = SephrTabArchiver()
    private var timer: Timer?
    private init() {}

    func start(maxAgeDays: Int = 30) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600,
                                      repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep(maxAgeDays: maxAgeDays) }
        }
    }

    private func sweep(maxAgeDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        let archived = SephrTabModel.shared.archivedTabs()
            .filter { $0.lastAccessedAt < cutoff }
        for tab in archived {
            SephrTabModel.shared.closeTab(tab)
        }
    }
}
