import SwiftUI

@main
struct SephrIOSApp: App {
    @State private var engine = BrowserEngine()
    @State private var favorites = FavoritesStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(favorites)
                .onOpenURL { url in
                    engine.openInNewTab(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                engine.snapshotActiveTab()
            }
        }
    }
}
