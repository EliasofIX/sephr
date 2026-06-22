import Foundation

/// A note on disk — may or may not still have a live tab in the sidebar.
struct SephrNoteSummary: Identifiable, Equatable {
    let id: UUID
    var title: String
    var modifiedAt: Date
}

/// Enumerates every note directory under Application Support, merging tab
/// metadata (title) when a matching `.note` tab still exists.
@MainActor
enum SephrNoteRegistry {

    private static var notesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Sephr/Notes", isDirectory: true)
    }

    static func allNotes() -> [SephrNoteSummary] {
        let root = notesRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var summaries: [SephrNoteSummary] = []
        summaries.reserveCapacity(entries.count)

        for dir in entries where dir.hasDirectoryPath {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let doc = dir.appendingPathComponent("note.json")
            guard FileManager.default.fileExists(atPath: doc.path) else { continue }

            let tab = SephrTabModel.shared.tab(withID: id)
            let title = tab.flatMap { $0.title.isEmpty ? nil : $0.title }
                ?? "Untitled Note"
            let modified = (try? doc.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            summaries.append(SephrNoteSummary(id: id, title: title, modifiedAt: modified))
        }

        return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
