import AppKit
import SwiftUI
import CAL

/// Downloads library — list in the middle, empty preview pane on the right.
struct SephrLibraryDownloadsView: View {

    @ObservedObject private var obs = SephrDownloadsObserver.shared
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [CALDownload] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return obs.downloads }
        return obs.downloads.filter {
            let name = ($0.targetPath.components(separatedBy: "/").last ?? "")
                .lowercased()
            return name.contains(q) || $0.sourceURL.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Divider().opacity(0.35)
            detailColumn
        }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Downloads…", text: $query)
                    .textFieldStyle(.plain)
                if !obs.downloads.isEmpty {
                    Button("Clear") { obs.clearVisible() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
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
                    obs.downloads.isEmpty ? "Nothing here yet!" : "No Matches",
                    systemImage: "arrow.down.circle",
                    description: Text(obs.downloads.isEmpty
                        ? "Come back after you've found some cool stuff to save."
                        : "Nothing matches “\(query)”."))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.identifier) { d in
                            downloadRow(d)
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

    private func downloadRow(_ d: CALDownload) -> some View {
        let selected = selection == d.identifier
        let filename = d.targetPath.components(separatedBy: "/").last ?? d.targetPath
        return Button {
            selection = d.identifier
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: d.state))
                    .foregroundStyle(iconColor(for: d.state))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(secondaryLine(for: d))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard, style: .continuous)
                    .fill(selected
                          ? Color.white.opacity(0.10)
                          : Color.clear))
        }
        .buttonStyle(.plain)
        .contextMenu { downloadContextMenu(for: d) }
    }

    @ViewBuilder
    private func downloadContextMenu(for d: CALDownload) -> some View {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        let svc = CALDownloads.sharedInstance(forProfile: pid)

        if d.state == .complete {
            Button("Open") { obs.open(d) }
            Button("Show in Finder") { obs.revealInFinder(d) }
        } else if d.state == .inProgress {
            Button("Pause") { svc.pause(d.identifier) }
            Button("Cancel", role: .destructive) { svc.cancel(d.identifier) }
        } else if d.state == .paused {
            Button("Resume") { svc.resume(d.identifier) }
            Button("Cancel", role: .destructive) { svc.cancel(d.identifier) }
        }

        if !d.sourceURL.isEmpty {
            Button("Copy Link") { obs.copyLink(d) }
        }

        Divider()

        Button("Remove from List") { obs.hide(d.identifier) }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selection,
           let d = obs.downloads.first(where: { $0.identifier == id }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(d.targetPath.components(separatedBy: "/").last ?? d.targetPath)
                    .font(.title3.weight(.semibold))
                Text(d.sourceURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                downloadActions(for: d)
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
                        "Select a Download",
                        systemImage: "arrow.down.circle",
                        description: Text("Pick a file from the list."))
                }
                .padding(12)
        }
    }

    @ViewBuilder
    private func downloadActions(for d: CALDownload) -> some View {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        let svc = CALDownloads.sharedInstance(forProfile: pid)
        HStack {
            if d.state == .complete {
                Button("Open") { obs.open(d) }
                    .buttonStyle(.borderedProminent)
                Button("Show in Finder") { obs.revealInFinder(d) }
            } else if d.state == .inProgress {
                Button("Pause") { svc.pause(d.identifier) }
                Button("Cancel") { svc.cancel(d.identifier) }
                    .foregroundStyle(.red)
            } else if d.state == .paused {
                Button("Resume") { svc.resume(d.identifier) }
            }
        }
    }

    private func iconName(for state: CALDownloadState) -> String {
        switch state {
        case .complete:   return "doc.fill"
        case .inProgress: return "arrow.down.circle.fill"
        case .paused:     return "pause.circle.fill"
        case .canceled:   return "xmark.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        @unknown default: return "doc"
        }
    }

    private func iconColor(for state: CALDownloadState) -> Color {
        switch state {
        case .complete:    return .secondary
        case .inProgress:  return .accentColor
        case .paused:      return .secondary
        case .canceled, .interrupted: return .red
        @unknown default:  return .secondary
        }
    }

    private func secondaryLine(for d: CALDownload) -> String {
        switch d.state {
        case .inProgress:
            if d.totalBytes > 0 {
                return "\(ByteCountFormatter.string(fromByteCount: d.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file))"
            }
            return ByteCountFormatter.string(fromByteCount: d.receivedBytes, countStyle: .file)
        case .paused:    return "Paused"
        case .complete:  return d.sourceURL
        case .canceled:  return "Canceled"
        case .interrupted: return "Failed"
        @unknown default: return d.sourceURL
        }
    }
}
