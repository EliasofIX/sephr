import SwiftUI

/// Minimal per-tab notes editor. One note per tab (keyed by tab ID),
/// rendered as Markdown while read-only, editable as plain text.
struct SephrNotesEditor: View {
    let tabID: UUID
    @State private var text: String = ""
    @State private var isEditing = false
    /// Trailing-edge debounce + background dispatch so each keystroke
    /// doesn't fire a synchronous main-thread disk write. 400 ms is
    /// well within the user's expectation that "switching off the
    /// editor saves" — manual save+commit also flushes the pending work.
    @State private var savePending: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                Toggle("Edit", isOn: $isEditing).toggleStyle(.switch)
                    .onChange(of: isEditing) { _, editing in
                        // Toggling off should flush any pending write so
                        // the on-disk content matches what's now visible
                        // as rendered Markdown.
                        if !editing { flushPending() }
                    }
            }
            .padding(12)

            Divider()

            if isEditing {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .padding(8)
                    .onChange(of: text) { _, new in scheduleSave(new) }
            } else if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                ScrollView {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                ScrollView { Text(text).padding(12) }
            }
        }
        .onAppear { text = load() }
        .onDisappear { flushPending() }
    }

    /// Directory containing all per-tab note files. Computed once per
    /// invocation but no longer re-created on every save — `mkdir -p`
    /// is cheap, but on a typing-rate path "cheap × N keystrokes"
    /// adds up.
    private static let notesDirectory: URL = {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("Sephr/Notes")
        try? FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        return dir
    }()

    private static let saveQueue = DispatchQueue(
        label: "sephr.notes.save", qos: .utility)

    private func path() -> URL {
        Self.notesDirectory.appendingPathComponent("\(tabID.uuidString).md")
    }

    private func load() -> String {
        (try? String(contentsOf: path(), encoding: .utf8)) ?? ""
    }

    private func scheduleSave(_ value: String) {
        savePending?.cancel()
        let target = path()
        let work = DispatchWorkItem {
            Self.saveQueue.async {
                try? value.write(to: target, atomically: true,
                                  encoding: .utf8)
            }
        }
        savePending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.4, execute: work)
    }

    private func flushPending() {
        if let work = savePending {
            work.cancel()
            savePending = nil
        }
        let target = path()
        let snapshot = text
        Self.saveQueue.async {
            try? snapshot.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}
