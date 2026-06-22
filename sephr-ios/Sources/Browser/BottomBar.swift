import SwiftUI

/// The three-glyph bottom bar: tabs · search · actions. One Liquid Glass
/// capsule docked at the bottom edge, no URL text while browsing — the
/// page is the UI. A luminous loading thread lives on the capsule's top
/// edge while loading.
///
/// The bar auto-collapses to a slim grabber pill when the user scrolls
/// down the page (the engine tracks the active web view's scroll position
/// and flips `engine.isBarCollapsed`). It re-expands on scroll up, when
/// the page returns to the top, or on navigation. The user can also pull
/// it down to collapse, pull it up to expand, or tap the grabber.
///
/// Horizontal swipes on the expanded bar cycle through recent tabs; a
/// sharp pull-up still opens the deck.
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
    @State private var verticalDrag: CGFloat = 0

    private var hasPage: Bool { engine.store.activeTab != nil }
    private var collapsed: Bool { engine.isBarCollapsed }
    private var collapseAnim: Animation? {
        reduceMotion ? nil
                     : .spring(response: 0.4, dampingFraction: 0.86)
    }

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                collapsedHandle
                    .transition(.opacity)
            } else {
                expandedBar
                    .transition(.opacity)
            }
        }
        .offset(x: collapsed ? 0 : dragOffset * 0.25)
        .offset(y: verticalDrag)
        .gesture(barGesture)
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: dragOffset)
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: verticalDrag)
        .animation(collapseAnim, value: collapsed)
    }

    // MARK: — Layouts

    private var expandedBar: some View {
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
        .dcGlass()
        .overlay(alignment: .top) {
            if engine.isLoading {
                ProgressHairline(progress: engine.estimatedProgress)
                    .padding(.horizontal, DC.Space.l)
                    .offset(y: -5)
            }
        }
    }

    /// Sheet-grabber idiom: a small ink pill that reads as "drag me". Tap
    /// or pull up to bring the full bar back. The 28pt minimum height keeps
    /// the tap target generous even though the pill itself is only 4pt.
    private var collapsedHandle: some View {
        Button {
            setCollapsed(false, haptic: true)
        } label: {
            VStack(spacing: 0) {
                Capsule(style: .continuous)
                    .fill(DC.Ink.ink3)
                    .frame(width: 40, height: 4)
                    .padding(.top, 10)
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dcGlass()
        .accessibilityLabel("Show Toolbar")
        .accessibilityHint("Pull up or tap to expand the toolbar")
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

    /// One drag handler does the job of three:
    ///  • horizontal on the expanded bar → cycle recent tabs
    ///  • pull-down on the expanded bar → collapse
    ///  • pull-up on the expanded bar (sharp) → open the deck
    ///  • pull-up on the collapsed handle → expand
    private var barGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height
                if abs(dy) > abs(dx) {
                    if collapsed {
                        verticalDrag = max(-60, min(0, dy))
                    } else {
                        verticalDrag = max(-60, min(60, dy))
                    }
                    dragOffset = 0
                } else if !collapsed {
                    dragOffset = max(-60, min(60, dx))
                    verticalDrag = 0
                }
            }
            .onEnded { v in
                let dx = v.translation.width
                let dy = v.translation.height
                let vy = v.velocity.height
                let verticalDominant = abs(dy) > abs(dx)

                if verticalDominant {
                    if collapsed {
                        if dy < -25 || vy < -500 {
                            setCollapsed(false, haptic: true)
                        }
                    } else if dy < -80 || vy < -1200 {
                        // Sharp pull up — keep the existing "open the
                        // deck" shortcut.
                        onTabs()
                    } else if dy < -25 {
                        // Soft pull up on an expanded bar acts as a no-op
                        // gesture; nothing to expand to.
                    } else if dy > 25 || vy > 500 {
                        setCollapsed(true, haptic: true)
                    }
                } else if !collapsed {
                    if dx > 50 {
                        engine.switchRelative(-1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } else if dx < -50 {
                        engine.switchRelative(1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragOffset = 0
                    verticalDrag = 0
                }
            }
    }

    private func setCollapsed(_ value: Bool, haptic: Bool) {
        guard engine.isBarCollapsed != value else { return }
        withAnimation(collapseAnim) {
            engine.isBarCollapsed = value
        }
        if haptic {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// Luminous loading thread along the capsule's top edge — layered black
/// bloom in light mode, white in dark. A traveling shimmer and leading
/// beacon give it an esoteric, seeking quality.
struct ProgressHairline: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let glow = dcDynamic(light: UIColor.black, dark: UIColor.white)

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: reduceMotion)
        ) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let shimmer = reduceMotion ? 0.5 : (sin(t * 2.2) * 0.5 + 0.5)
            let breathe = reduceMotion ? 1.0 : (0.86 + 0.14 * (sin(t * 1.5) * 0.5 + 0.5))

            GeometryReader { geo in
                let fill = max(16, geo.size.width * progress)
                let band = min(fill * 0.38, 52)

                ZStack(alignment: .leading) {
                    // Diffuse outer halo
                    Capsule()
                        .fill(glow.opacity(0.10))
                        .frame(width: fill + 10, height: 14)
                        .blur(radius: 9)

                    // Mid bloom
                    Capsule()
                        .fill(glow.opacity(0.24))
                        .frame(width: fill, height: 6)
                        .blur(radius: 4)

                    // Core thread — bright at the frontier, fading behind
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: glow.opacity(0.25), location: 0),
                                    .init(color: glow.opacity(0.70), location: 0.72),
                                    .init(color: glow, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing))
                        .frame(width: fill, height: 1.5)
                        .shadow(color: glow.opacity(0.60), radius: 2)
                        .shadow(color: glow.opacity(0.35), radius: 6)
                        .shadow(color: glow.opacity(0.18), radius: 14)

                    // Traveling shimmer — a pulse of light along the thread
                    if fill > 28, !reduceMotion {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, glow.opacity(0.95), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing))
                            .frame(width: band, height: 1.5)
                            .offset(x: (fill - band) * shimmer)
                            .mask(alignment: .leading) {
                                Capsule().frame(width: fill, height: 3)
                            }
                    }

                    // Leading beacon — the seeking point at the frontier
                    Circle()
                        .fill(glow)
                        .frame(width: 3, height: 3)
                        .shadow(color: glow.opacity(0.90), radius: 4)
                        .shadow(color: glow.opacity(0.50), radius: 10)
                        .offset(x: fill - 1.5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .opacity(breathe)
                .animation(.linear(duration: 0.2), value: progress)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
