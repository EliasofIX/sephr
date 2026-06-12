import SwiftUI

/// The three-glyph bottom bar: tabs · search · actions. One Liquid Glass
/// capsule docked at the bottom edge, no URL text while browsing — the
/// page is the UI. A hairline progress line lives on the capsule's top
/// edge while loading. Horizontal swipes on the bar cycle through recent
/// tabs; swiping up on the tabs glyph opens the deck.
struct BottomBar: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(FavoritesStore.self) private var favorites
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onTabs: () -> Void
    let onSearch: () -> Void
    let onIncognitoSearch: () -> Void
    let onShowAddressBar: () -> Void
    let onReader: () -> Void
    let onShare: () -> Void

    @State private var dragOffset: CGFloat = 0

    private var hasPage: Bool { engine.store.activeTab != nil }

    var body: some View {
        HStack(spacing: 0) {
            barButton("square.on.square", label: "Tabs", action: onTabs)
                .accessibilityHint("Swipe up for the tab deck")

            barButton("plus", label: "New Tab", size: 22, action: onSearch)
                .contextMenu {
                    Button {
                        onIncognitoSearch()
                    } label: {
                        Label("New Incognito Tab",
                              systemImage: "eyeglasses")
                    }
                }

            actionsMenu
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if engine.isLoading {
                ProgressHairline(progress: engine.estimatedProgress)
                    .padding(.horizontal, DC.Space.l)
            }
        }
        .dcGlass(cornerRadius: 28)
        .offset(x: dragOffset * 0.25)
        .gesture(barSwipe)
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: dragOffset)
    }

    // MARK: — Pieces

    private func barButton(_ symbol: String, label: String,
                           size: CGFloat = 18,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(DC.Ink.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var actionsMenu: some View {
        Menu {
            if hasPage {
                Section {
                    Button(action: onShowAddressBar) {
                        Label(engine.currentURL?.host() ?? "Address",
                              systemImage: "link")
                    }
                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        if let url = engine.currentURL {
                            UIPasteboard.general.url = url
                        }
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
                Section {
                    Button(action: onReader) {
                        Label("Reader Mode", systemImage: "text.justify.left")
                    }
                    Button { engine.presentFindInPage() } label: {
                        Label("Find in Page", systemImage: "magnifyingglass")
                    }
                    Button { engine.toggleDesktopSite() } label: {
                        Label(engine.activeTabIsDesktop
                              ? "Request Mobile Site"
                              : "Request Desktop Site",
                              systemImage: "desktopcomputer")
                    }
                    zoomMenu
                }
                Section {
                    favoriteButton
                    Button {
                        if engine.isLoading { engine.stop() }
                        else { engine.reload() }
                    } label: {
                        Label(engine.isLoading ? "Stop" : "Reload",
                              systemImage: engine.isLoading
                                  ? "xmark" : "arrow.clockwise")
                    }
                }
                Section {
                    Button { engine.goBack() } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!engine.canGoBack)
                    Button { engine.goForward() } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!engine.canGoForward)
                }
                Section {
                    Button(role: .destructive) {
                        engine.archiveActiveTab()
                    } label: {
                        Label("Archive Tab", systemImage: "archivebox")
                    }
                }
            } else {
                Button(action: onSearch) {
                    Label("New Tab", systemImage: "plus")
                }
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(hasPage ? DC.Ink.ink : DC.Ink.ink4)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Page Actions")
    }

    private var favoriteButton: some View {
        Button {
            guard let url = engine.currentURL,
                  let tab = engine.store.activeTab else { return }
            favorites.toggle(url: url, title: tab.displayTitle)
        } label: {
            Label(favorites.isFavorite(engine.currentURL)
                  ? "Remove Favorite" : "Add to Favorites",
                  systemImage: favorites.isFavorite(engine.currentURL)
                  ? "star.fill" : "star")
        }
    }

    private var zoomMenu: some View {
        Menu {
            ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { zoom in
                Button {
                    engine.pageZoom = zoom
                } label: {
                    if abs(engine.pageZoom - zoom) < 0.01 {
                        Label("\(Int(zoom * 100))%", systemImage: "checkmark")
                    } else {
                        Text("\(Int(zoom * 100))%")
                    }
                }
            }
        } label: {
            Label("Page Zoom", systemImage: "textformat.size")
        }
    }

    // MARK: — Gestures

    /// Horizontal drag across the capsule cycles recent tabs, Safari-bar
    /// style. The capsule nudges with the finger, then springs back.
    private var barSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    dragOffset = max(-60, min(60, value.translation.width))
                }
            }
            .onEnded { value in
                defer { dragOffset = 0 }
                let dx = value.translation.width
                let dy = value.translation.height
                if dy < -40 && abs(dy) > abs(dx) {
                    onTabs()
                } else if dx > 50 {
                    engine.switchRelative(-1)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else if dx < -50 {
                    engine.switchRelative(1)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

/// The loading indicator: a single hairline of ink growing along the
/// capsule's top edge. No spinner, no color.
struct ProgressHairline: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(DC.Ink.ink)
                .frame(width: max(8, geo.size.width * progress), height: 2)
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
