import SwiftUI

/// Archived tabs library — macOS already archives idle tabs; this surface
/// lets you browse and restore them.
struct SephrLibraryArchivedView: View {

    var onRestore: (SephrTab) -> Void

    @State private var tabs: [SephrTab] = []
    @State private var query = ""
    @State private var selection: UUID?

    private var filtered: [SephrTab] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Divider().opacity(0.35)
            detailColumn
        }
        .onAppear { tabs = SephrTabModel.shared.archivedTabs() }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Archive…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if filtered.isEmpty {
                Spacer()
                ContentUnavailableView(
                    tabs.isEmpty ? "Archive is empty" : "No Matches",
                    systemImage: "archivebox",
                    description: Text(tabs.isEmpty
                        ? "Tabs you stop using will appear here."
                        : "Nothing matches “\(query)”."))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { tab in
                            archivedRow(tab)
                            Divider().opacity(0.25)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.18))
    }

    private func archivedRow(_ tab: SephrTab) -> some View {
        let selected = selection == tab.id
        return Button {
            selection = tab.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.kind == .note ? "square.and.pencil" : "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title.isEmpty ? tab.url : tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if tab.kind == .web, !tab.url.isEmpty {
                        Text(tab.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selection,
           let tab = tabs.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.title3.weight(.semibold))
                if tab.kind == .web, !tab.url.isEmpty {
                    Text(tab.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Archived \(tab.lastAccessedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Restore to Sidebar") {
                    SephrTabModel.shared.restoreFromArchive(tab)
                    onRestore(tab)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.22)))
            .padding(12)
        } else {
            RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
                .overlay {
                    ContentUnavailableView(
                        "Select an Archived Tab",
                        systemImage: "archivebox",
                        description: Text("Pick a tab to restore it to your sidebar."))
                }
                .padding(12)
        }
    }
}
