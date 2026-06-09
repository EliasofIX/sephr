import SwiftUI
import AppKit

enum LibraryTab: String, CaseIterable, Identifiable {
    case history, downloads, screenshots, archived
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemIcon: String {
        switch self {
        case .history:     return "clock"
        case .downloads:   return "arrow.down.circle"
        case .screenshots: return "rectangle.dashed"
        case .archived:    return "archivebox"
        }
    }
}

struct SephrLibraryPanel: View {
    @State private var selection: LibraryTab = .history

    var body: some View {
        NavigationSplitView {
            List(LibraryTab.allCases, selection: $selection) { tab in
                Label(tab.label, systemImage: tab.systemIcon)
                    .tag(tab)
            }
            .navigationTitle("Library")
            .frame(minWidth: 180)
        } detail: {
            switch selection {
            case .history:     SephrHistoryView()
            case .downloads:   SephrDownloadsPanel()
            case .screenshots: ScreenshotsView()
            case .archived:    ArchivedTabsView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct ScreenshotsView: View {
    var body: some View {
        ContentUnavailableView("No Screenshots Yet",
            systemImage: "rectangle.dashed",
            description: Text("Screenshots captured via Peek or Easels will appear here."))
    }
}

@MainActor
private struct ArchivedTabsView: View {
    @State private var tabs: [SephrTab] = []
    var body: some View {
        List(tabs) { tab in
            HStack {
                Image(systemName: "globe").foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(tab.title.isEmpty ? tab.url : tab.title)
                    Text(tab.url).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { tabs = SephrTabModel.shared.archivedTabs() }
    }
}

// SephrTab already conforms to Identifiable via its own declaration
// (see Tabs/SephrTab.swift); the extension here was a duplicate
// conformance that newer Swift compilers reject.
