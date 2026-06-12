import SwiftUI

/// Top-level state machine: onboarding on first run, then the browser
/// shell.
struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        if onboarded {
            BrowserShell()
        } else {
            OnboardingView { onboarded = true }
        }
    }
}

/// The browser proper: full-bleed web content, the three-glyph bottom
/// bar, and the three overlays (search takeover, tab deck, sheets).
struct BrowserShell: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var searchPresented = false
    @State private var searchIntent: SearchIntent = .newTab
    @State private var deckPresented = false
    @State private var settingsPresented = false
    @State private var archivePresented = false
    @State private var readerPresented = false
    @State private var sharePresented = false

    enum SearchIntent {
        case newTab            // "+" — submission opens a fresh tab
        case newIncognitoTab
        case editCurrent       // address-bar reveal — edits the active tab
    }

    var body: some View {
        @Bindable var engine = engine
        ZStack {
            DC.Ink.field.ignoresSafeArea()

            // Web content, full bleed — the page is the UI.
            if let tab = engine.store.activeTab {
                BrowserWebView(webView: engine.pool.view(for: tab))
                    .ignoresSafeArea(edges: .bottom)
                    .id(tab.id)
            } else {
                EmptyDeckView()
            }

            // Incognito badge.
            if engine.store.activeTab?.isIncognito == true {
                VStack {
                    Text("Incognito")
                        .dcLabel()
                        .padding(.horizontal, DC.Space.m)
                        .padding(.vertical, 6)
                        .dcGlass(cornerRadius: 12)
                    Spacer()
                }
                .padding(.top, DC.Space.s)
            }

            // Bottom chrome.
            VStack(spacing: 0) {
                Spacer()
                BottomBar(
                    onTabs: {
                        engine.snapshotActiveTab()
                        withAnimation(.spring(response: 0.4,
                                              dampingFraction: 0.88)) {
                            deckPresented = true
                        }
                    },
                    onSearch: {
                        searchIntent = .newTab
                        searchPresented = true
                    },
                    onIncognitoSearch: {
                        searchIntent = .newIncognitoTab
                        searchPresented = true
                    },
                    onShowAddressBar: {
                        searchIntent = .editCurrent
                        searchPresented = true
                    },
                    onReader: { readerPresented = true },
                    onShare: { sharePresented = true })
                    .frame(maxWidth: sizeClass == .regular ? 520 : .infinity)
            }
            .padding(.horizontal, DC.Space.l)
            .padding(.bottom, DC.Space.s)

            // Tab deck takeover.
            if deckPresented {
                TabDeckView(
                    onDismiss: {
                        withAnimation(.spring(response: 0.4,
                                              dampingFraction: 0.88)) {
                            deckPresented = false
                        }
                    },
                    onNewTab: {
                        deckPresented = false
                        searchIntent = .newTab
                        searchPresented = true
                    },
                    onSettings: { settingsPresented = true },
                    onArchive: { archivePresented = true })
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(2)
            }

            // Search takeover.
            if searchPresented {
                SearchOverlayView(intent: searchIntent) {
                    searchPresented = false
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView() }
        .sheet(isPresented: $archivePresented) {
            ArchiveView { id in
                archivePresented = false
                deckPresented = false
                engine.switchTo(id)
            }
        }
        .sheet(isPresented: $readerPresented) { ReaderModeView() }
        .sheet(isPresented: $sharePresented) {
            if let url = engine.currentURL {
                ShareSheet(items: [url])
                    .presentationDetents([.medium])
            }
        }
        .onChange(of: engine.pendingPopupURL) { _, url in
            guard let url else { return }
            engine.pendingPopupURL = nil
            engine.openInNewTab(
                url, incognito: engine.store.activeTab?.isIncognito ?? false)
        }
        .onAppear {
            // The signature move: cold-open straight into search,
            // keyboard up — unless a page is there to resume.
            if engine.store.activeTab == nil {
                searchIntent = .newTab
                searchPresented = true
            }
        }
        .preferredColorScheme(nil)
        .statusBarHidden(false)
    }
}

/// All tabs cleared: a quiet field with the asterism, spinnable — the
/// Sephr fidget.
struct EmptyDeckView: View {
    @State private var spin: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DC.Space.l) {
            Text("✺")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(DC.Ink.ink4)
                .rotationEffect(spin)
                .onTapGesture {
                    guard !reduceMotion else { return }
                    withAnimation(.spring(response: 1.2,
                                          dampingFraction: 0.45)) {
                        spin += .degrees(360)
                    }
                }
            Text("Nothing open")
                .font(DC.TypeScale.callout)
                .foregroundStyle(DC.Ink.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No open tabs")
    }
}

/// UIKit share sheet bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items,
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController,
                                context: Context) {}
}
