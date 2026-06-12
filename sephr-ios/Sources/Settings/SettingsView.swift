import SwiftUI

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
                    Toggle("Block Ads & Trackers", isOn: $contentBlocking)
                        .onChange(of: contentBlocking) { _, enabled in
                            engine.pool.setContentBlocking(enabled)
                        }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Blocks common ad networks, trackers, and cookie "
                         + "banners. Pages load faster and cleaner.")
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
