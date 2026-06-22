import SwiftUI

/// Notes library — searchable grid in the middle column, live canvas on
/// the right (Arc Easels layout, simplified).
struct SephrLibraryNotesView: View {

    var onOpenNote: (UUID) -> Void

    @State private var notes: [SephrNoteSummary] = []
    @State private var query = ""
    @State private var selection: UUID?

    private var filtered: [SephrNoteSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Divider().opacity(0.35)
            detailColumn
        }
        .onAppear { reload() }
        .onChange(of: selection) { _, id in
            if let id { ensureTabShell(for: id) }
        }
    }

    // MARK: — List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Notes…", text: $query)
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
                    notes.isEmpty ? "No Notes Yet" : "No Matches",
                    systemImage: "square.and.pencil",
                    description: Text(notes.isEmpty
                        ? "Create a note from the sidebar + menu."
                        : "Nothing matches “\(query)”."))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(filtered) { note in
                            noteCard(note)
                        }
                    }
                    .padding(14)
                }
            }

            Button {
                let tab = SephrTabModel.shared.newNote(
                    in: SephrSpaceManager.shared.currentSpace)
                reload()
                selection = tab.id
                onOpenNote(tab.id)
            } label: {
                Label("New Note", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.18))
    }

    private func noteCard(_ note: SephrNoteSummary) -> some View {
        let selected = selection == note.id
        return Button {
            selection = note.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.pink.opacity(0.85))
                Text(note.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)
                        .opacity(selected ? 0.55 : 0.32)))
            .overlay(
                RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.35) : .clear,
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: — Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selection, let tab = SephrTabModel.shared.tab(withID: id) {
            SephrNoteCanvas(tab: tab)
                .clipShape(RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous))
                .padding(12)
                .overlay(alignment: .topTrailing) {
                    Button("Open in Tab") { onOpenNote(id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(20)
                }
        } else {
            RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
                .overlay {
                    ContentUnavailableView(
                        "Select a Note",
                        systemImage: "square.and.pencil",
                        description: Text("Pick a note from the grid to preview it."))
                }
                .padding(12)
        }
    }

    private func reload() {
        notes = SephrNoteRegistry.allNotes()
        if let sel = selection, !notes.contains(where: { $0.id == sel }) {
            selection = notes.first?.id
        } else if selection == nil {
            selection = notes.first?.id
        }
        if let id = selection { ensureTabShell(for: id) }
    }

    private func ensureTabShell(for id: UUID) {
        guard SephrTabModel.shared.tab(withID: id) == nil,
              notes.contains(where: { $0.id == id }) else { return }
        let title = notes.first(where: { $0.id == id })?.title ?? "Untitled Note"
        _ = SephrTabModel.shared.reopenNote(
            id: id, title: title,
            in: SephrSpaceManager.shared.currentSpace)
    }
}
