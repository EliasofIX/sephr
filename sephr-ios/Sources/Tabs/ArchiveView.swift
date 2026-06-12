import SwiftUI

/// The archive: everything that aged out of the deck (or was flicked
/// away), searchable, restorable. Doubles as history's front door.
struct ArchiveView: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    let onRestore: (UUID) -> Void

    @State private var query = ""
    @State private var confirmingClear = false

    private var results: [SephrTab] {
        let archived = engine.store.archivedTabs
        let q = query.lowercased()
        guard !q.isEmpty else { return archived }
        return archived.filter {
            $0.displayTitle.lowercased().contains(q)
                || ($0.url?.absoluteString.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Archive is empty"
                                      : "No matches",
                        systemImage: "archivebox",
                        description: Text(query.isEmpty
                            ? "Tabs you haven't touched in a while end up here."
                            : "Nothing in the archive matches “\(query)”."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(results) { tab in
                        Button {
                            onRestore(tab.id)
                        } label: {
                            HStack(spacing: DC.Space.m) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.displayTitle)
                                        .font(DC.TypeScale.callout)
                                        .foregroundStyle(DC.Ink.ink)
                                        .lineLimit(1)
                                    Text(tab.url?.host() ?? "")
                                        .font(DC.TypeScale.caption)
                                        .foregroundStyle(DC.Ink.ink3)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(tab.lastAccessedAt,
                                     format: .relative(presentation: .named))
                                    .font(DC.TypeScale.caption)
                                    .foregroundStyle(DC.Ink.ink4)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                engine.store.close(tab.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search archive")
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) {
                        confirmingClear = true
                    }
                    .disabled(engine.store.archivedTabs.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear the entire archive?",
                                isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Clear Archive", role: .destructive) {
                    engine.store.clearArchive()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
