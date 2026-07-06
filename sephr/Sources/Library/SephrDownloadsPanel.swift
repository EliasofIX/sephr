import AppKit
import SwiftUI
import CAL

struct SephrDownloadsPanel: View {

    @ObservedObject private var obs = SephrDownloadsObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                if !obs.downloads.isEmpty {
                    Button("Clear") { obs.clearVisible() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            if obs.downloads.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No downloads yet")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(obs.downloads, id: \.identifier) { d in
                            DownloadRow(d: d)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 320)
    }
}

private struct DownloadRow: View {
    let d: CALDownload

    private var obs: SephrDownloadsObserver { .shared }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if d.state == .inProgress, d.totalBytes > 0 {
                        ProgressView(
                            value: Double(d.receivedBytes),
                            total: Double(d.totalBytes))
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                SephrDownloadRowClickSurface(
                    onClick: { rowClicked() },
                    menu: { SephrDownloadMenuBuilder.menu(for: d) })
            }

            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func rowClicked() {
        switch d.state {
        case .complete:
            obs.open(d)
        case .inProgress:
            downloadsService.pause(d.identifier)
        case .paused:
            downloadsService.resume(d.identifier)
        case .canceled, .interrupted:
            break
        @unknown default:
            break
        }
    }

    private var downloadsService: CALDownloads {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        return CALDownloads.sharedInstance(forProfile: pid)
    }

    private var filename: String {
        (d.targetPath.components(separatedBy: "/").last) ?? d.targetPath
    }

    private var secondaryLine: String {
        switch d.state {
        case .inProgress:
            if d.totalBytes > 0 {
                return "\(ByteCountFormatter.string(fromByteCount: d.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file))"
            }
            return ByteCountFormatter.string(
                fromByteCount: d.receivedBytes, countStyle: .file)
        case .paused:    return "Paused"
        case .complete:  return d.sourceURL
        case .canceled:  return "Canceled"
        case .interrupted: return "Failed"
        @unknown default: return d.sourceURL
        }
    }

    private var iconName: String {
        switch d.state {
        case .complete:   return "doc.fill"
        case .inProgress: return "arrow.down.circle.fill"
        case .paused:     return "pause.circle.fill"
        case .canceled:   return "xmark.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        @unknown default: return "doc"
        }
    }

    private var iconColor: Color {
        switch d.state {
        case .complete:    return .secondary
        case .inProgress:  return .accentColor
        case .paused:      return .secondary
        case .canceled, .interrupted: return .red
        @unknown default:  return .secondary
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if d.state == .inProgress {
                Button {
                    downloadsService.pause(d.identifier)
                } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.borderless)
                Button {
                    downloadsService.cancel(d.identifier)
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
            } else if d.state == .paused {
                Button {
                    downloadsService.resume(d.identifier)
                } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
            } else if d.state == .complete {
                Button {
                    obs.revealInFinder(d)
                } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .foregroundStyle(.secondary)
    }
}
