import SwiftUI

/// One row showing the on-device model's current state. Shares the
/// monochrome ink ramp with the rest of the Form so it doesn't shout.
struct IntelligencePaneRow: View {
    let model: ModelManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("LFM2-VL-450M · BF16")
                    .font(DC.TypeScale.callout)
                Text(detail)
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink3)
            }
            Spacer()
            statusBadge
        }
        .task { model.prepare() }
    }

    private var detail: String {
        switch model.state {
        case .missing:
            return "Not downloaded · ~711 MB"
        case let .downloading(progress):
            let percent = Int((progress * 100).rounded())
            return "Downloading · \(percent)%"
        case .warming:
            return "Warming on-device runtime…"
        case .ready:
            return "Ready · running on this device"
        case let .error(message):
            return message
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.state {
        case .missing:
            Text("Download").dcLabel()
        case .downloading, .warming:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Text("Ready").dcLabel()
        case .error:
            Text("Error").dcLabel()
        }
    }
}

/// Settings sheet — a standard Form (the system pattern), monochrome by
/// inheritance of the DC ramp.
struct SettingsView: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var searchEngine = URLBuilder.engine
    @AppStorage("contentBlocking") private var contentBlocking = true
    @State private var confirmingHistoryClear = false

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    private var isModelDownloading: Bool {
        if case .downloading = engine.model.state { return true }
        return false
    }

    var body: some View {
        @Bindable var store = engine.store
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search Engine", selection: $searchEngine) {
                        ForEach(URLBuilder.Engine.allCases) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .onChange(of: searchEngine) { _, newValue in
                        URLBuilder.engine = newValue
                    }
                }

                Section {
                    Picker("Archive Tabs After",
                           selection: $store.archiveHorizon) {
                        ForEach(TabStore.ArchiveHorizon.allCases) { horizon in
                            Text(horizon.label).tag(horizon)
                        }
                    }
                } header: {
                    Text("Tabs")
                } footer: {
                    Text("Tabs you haven't opened in this long move to the "
                         + "archive on their own. Pinned tabs stay put.")
                }

                Section {
                    Toggle("uBlock Origin", isOn: $contentBlocking)
                        .onChange(of: contentBlocking) { _, enabled in
                            engine.pool.setContentBlocking(enabled)
                        }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Network lists from uBlock Origin, EasyList, and "
                         + "EasyPrivacy. Cookie banners are hidden with CSS.")
                }

                Section {
                    Button("Clear Browsing History", role: .destructive) {
                        confirmingHistoryClear = true
                    }
                }

                Section("Default Browser") {
                    Button("Set Sephr as Default Browser…") {
                        if let url = URL(
                            string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    IntelligencePaneRow(model: engine.model)
                    Button("Reload Model") {
                        engine.model.resetAndRedownload()
                    }
                    .disabled(isModelDownloading)
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text("SuperBrowse and Summarize run the full-"
                         + "precision (~711 MB) LFM2-VL-450M model on "
                         + "this device. Prompts and page text never "
                         + "leave your phone.\n\n"
                         + "Model © Liquid AI, licensed under the "
                         + "LFM Open License v1.0.")
                        .font(DC.TypeScale.caption)
                }

                Section("About") {
                    HStack {
                        SephrLogo(size: 16)
                        Text("Sephr for iOS")
                            .font(DC.TypeScale.callout)
                        Spacer()
                        Text(appVersion)
                            .font(DC.TypeScale.data)
                            .foregroundStyle(DC.Ink.ink3)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all browsing history?",
                                isPresented: $confirmingHistoryClear,
                                titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    engine.history.clear()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
