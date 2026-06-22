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

            // Web content, full bleed — the page is the UI. Tabs with no
            // URL yet keep the empty-deck treatment so we don't mount a
            // blank WKWebView over the whole screen.
            if let tab = engine.store.activeTab, tab.hasBrowsableURL {
                BrowserWebView(
                    webView: engine.pool.view(for: tab),
                    onSummarize: { engine.startSummarize() })
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
                        .dcGlass()
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

            // SuperBrowse takeover — hero during fetch/read, then the
            // result view once the model starts generating. Same z so
            // they swap in place without any cross-fade artifact.
            if let session = engine.superBrowseSession {
                SuperBrowseContainer(session: session)
                    .transition(.opacity)
                    .zIndex(4)
            }

            // Summarize takeover — origami fold + summary card. Mutually
            // exclusive with SuperBrowse at the engine level, so we'll
            // only ever mount one of these at a time.
            if let session = engine.summarizeSession {
                SummarizeOverlay(
                    session: session,
                    onDismiss: { engine.dismissSummarize() },
                    onExpandBack: { engine.dismissSummarize() })
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(4)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9),
                   value: engine.superBrowseSession != nil)
        .animation(.spring(response: 0.45, dampingFraction: 0.88),
                   value: engine.summarizeSession != nil)
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
        .task(id: engine.store.activeTabID) {
            engine.syncActiveWebView()
        }
        .task {
            guard engine.store.activeTab?.hasBrowsableURL != true else { return }
            searchIntent = .newTab
            searchPresented = true
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
