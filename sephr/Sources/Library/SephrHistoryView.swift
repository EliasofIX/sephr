import SwiftUI
import CAL

struct SephrHistoryView: View {

    @State private var query = ""
    @State private var entries: [CALHistoryEntry] = []
    /// Trailing-edge debounce so a 10-character query doesn't fire 10
    /// HistoryService round-trips. 150 ms reads as instant but coalesces
    /// the user's typing into one query.
    @State private var refreshPending: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search history...", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { refresh() }
                .onChange(of: query) { _, _ in scheduleRefresh() }

            List(entries, id: \.url) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body)
                    Text(entry.url).font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.visitedAt.formatted(.dateTime))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { refresh() }
        .onDisappear { refreshPending?.cancel() }
    }

    @MainActor
    private func scheduleRefresh() {
        refreshPending?.cancel()
        let work = DispatchWorkItem { refresh() }
        refreshPending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15, execute: work)
    }

    @MainActor
    private func refresh() {
        refreshPending = nil
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        let history = CALHistory(forProfile: pid)
        if query.isEmpty {
            history.entries(after: Date.distantPast,
                             before: Date()) { self.entries = $0 }
        } else {
            history.searchText(query, limit: 200) { self.entries = $0 }
        }
    }
}
