import AppKit
import SwiftUI
import SephrKit

// MARK: - Model

/// UI snapshot the pill renders. Fed by `SephrNowPlayingPill` from the
/// playing tab's live CALWebView state; SwiftUI animates between snapshots.
final class SephrNowPlayingModel: ObservableObject {
    @Published var hasSession = false
    @Published var favicon: NSImage?
    @Published var title = ""
    @Published var artist: String?
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var canPrev = false
    @Published var canNext = false

    // Wired by SephrNowPlayingPill to the playing tab.
    var onSelect: (() -> Void)?
    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onMute: (() -> Void)?
    var onDismiss: (() -> Void)?
}

// MARK: - SwiftUI content

/// One transport button: plain SF Symbol with a soft circular hover wash.
private struct NowPlayingControl: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(.primary.opacity(hovering && !disabled ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NowPlayingPillView: View {
    @ObservedObject var model: SephrNowPlayingModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.hasSession {
                pill
                    .transition(reduceMotion ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25),
                   value: model.hasSession)
    }

    private static let hoverCollapseDuration = 0.18
    private static let headerFadeOutDuration = 0.08
    private static let headerFadeInDuration = 0.12

    private var pill: some View {
        VStack(spacing: 0) {
            // Hover-expanded header: what's playing + dismiss, Zen-style.
            // Kept in the hierarchy (not `if hovering`) so collapse can fade
            // text out before the transport row rises — avoids title/artist
            // painting over the play button mid-animation.
            expandedHeader

            HStack(spacing: 2) {
                Button {
                    model.onSelect?()
                } label: {
                    Group {
                        if let favicon = model.favicon {
                            Image(nsImage: favicon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5,
                                                            style: .continuous))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: DC.Radius.standard))
                }
                .buttonStyle(.plain)
                .help("Go to Playing Tab")
                .accessibilityLabel("Go to playing tab: \(model.title)")

                Spacer(minLength: 2)

                NowPlayingControl(symbol: "backward.fill",
                                  label: "Previous Track",
                                  disabled: !model.canPrev) {
                    model.onPrev?()
                }
                NowPlayingControl(symbol: model.isPlaying ? "pause.fill"
                                                          : "play.fill",
                                  label: model.isPlaying ? "Pause" : "Play") {
                    model.onPlayPause?()
                }
                NowPlayingControl(symbol: "forward.fill",
                                  label: "Next Track",
                                  disabled: !model.canNext) {
                    model.onNext?()
                }

                Spacer(minLength: 2)

                NowPlayingControl(symbol: model.isMuted
                                  ? "speaker.slash.fill"
                                  : "speaker.wave.2.fill",
                                  label: model.isMuted ? "Unmute Tab"
                                                       : "Mute Tab") {
                    model.onMute?()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .modifier(NowPlayingGlass())
        .onHover { inside in
            withAnimation(reduceMotion ? nil
                          : .snappy(duration: Self.hoverCollapseDuration)) {
                hovering = inside
            }
        }
        // Margin between the glass and the sidebar edges / neighbors —
        // also breathing room for Liquid Glass's soft ambient shadow.
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var expandedHeader: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = model.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            NowPlayingControl(symbol: "xmark",
                              label: "Hide Player") {
                model.onDismiss?()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .opacity(hovering ? 1 : 0)
        .frame(maxHeight: hovering ? nil : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(hovering)
        .accessibilityHidden(!hovering)
        .animation(reduceMotion ? nil : headerOpacityAnimation, value: hovering)
    }

    private var headerOpacityAnimation: Animation {
        hovering
            ? .easeOut(duration: Self.headerFadeInDuration)
                .delay(Self.hoverCollapseDuration * 0.25)
            : .easeOut(duration: Self.headerFadeOutDuration)
    }
}

/// Real macOS 26 Liquid Glass, applied DIRECTLY on the content — no manual
/// shadow, no outer clipShape (the clip is what chops the glass shadow into
/// a hard box). Material fallback only on pre-26 systems.
private struct NowPlayingGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DC.Radius.standard,
                                     style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

// MARK: - AppKit host + tab tracking

/// Sidebar-bottom Now Playing pill (Zen-style). Appears whenever any tab —
/// in any space — has a controllable media session or is emitting audio;
/// shows that tab's favicon, transport controls, and per-tab mute. Clicking
/// the favicon jumps to the tab (switching spaces if needed). Self-contained:
/// observes the app-wide media notification and re-resolves which tab to
/// surface, so the sidebar just installs it between the tab list and footer.
final class SephrNowPlayingPill: NSView {

    private let model = SephrNowPlayingModel()
    private var hostingView: NSHostingView<NowPlayingPillView>!

    /// The tab the pill currently surfaces. Weak — closing the tab must not
    /// keep it (or its WebContents) alive; structure events re-resolve.
    private weak var currentTab: SephrTab?
    /// Bus subscription following `currentTab` (favicon / title / audio /
    /// media repaints). Re-anchored whenever the pill retargets.
    private var tabToken: TabEventToken?
    private var structureToken: TabEventToken?
    /// Tab the user dismissed via the pill's ✕. Ignored until its session
    /// ends (navigate away / silence); any OTHER tab starting media still
    /// takes the pill over.
    private weak var dismissedTab: SephrTab?

    override init(frame: NSRect) {
        super.init(frame: frame)

        let root = NowPlayingPillView(model: model)
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = .intrinsicContentSize
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        model.onSelect = { [weak self] in
            guard let tab = self?.currentTab else { return }
            self?.jump(to: tab)
        }
        model.onPrev = { [weak self] in self?.currentTab?.mediaPreviousTrack() }
        model.onPlayPause = { [weak self] in self?.currentTab?.mediaPlayPause() }
        model.onNext = { [weak self] in self?.currentTab?.mediaNextTrack() }
        model.onMute = { [weak self] in self?.currentTab?.toggleMute() }
        model.onDismiss = { [weak self] in
            guard let self else { return }
            self.dismissedTab = self.currentTab
            self.retarget()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(mediaChanged(_:)),
            name: .sephrTabMediaChanged, object: nil)
        // Tab closed / model rebuilt — the playing tab may be gone.
        structureToken = TabEventBus.shared.subscribeStructure { [weak self] in
            self?.retarget()
        }
        retarget()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Tab tracking

    @objc private func mediaChanged(_ note: Notification) {
        // A tab whose dismissed session fully ended comes off the blocklist,
        // so the NEXT thing it plays surfaces again.
        if let dismissed = dismissedTab, !Self.qualifies(dismissed) {
            dismissedTab = nil
        }
        retarget()
    }

    /// True when `tab` is worth surfacing: a controllable media session
    /// (playing OR paused — paused keeps the pill up with a play button,
    /// like Zen) or plain audible output from a page that never adopted the
    /// Media Session API.
    private static func qualifies(_ tab: SephrTab) -> Bool {
        tab.webView != nil && (tab.isMediaControllable || tab.isAudible)
    }

    /// Re-resolve which tab the pill should surface and repaint. Sticky:
    /// the current tab keeps the pill while it qualifies (a paused session
    /// isn't stolen by a brief sound elsewhere unless that sound is a real
    /// playing session).
    private func retarget() {
        let model = SephrTabModel.shared
        // Fast path: when the current tab is actively playing and still
        // qualifies, nothing in the model can preempt it (an audible /
        // paused candidate doesn't displace a playing session). Skip the
        // O(n) candidate scan — audio events can fire 5–50/sec during
        // playback and this is the runtime-hot route through here.
        if let cur = currentTab,
           cur !== dismissedTab,
           Self.qualifies(cur),
           cur.isMediaPlaying {
            refresh()
            return
        }

        let candidates = model.allTabs.filter {
            Self.qualifies($0) && $0 !== dismissedTab
        }

        var next = (currentTab.map { Self.qualifies($0) && $0 !== dismissedTab } == true)
            ? currentTab : nil
        // An actively-playing tab takes over from a merely-paused/audible one.
        if let playing = candidates.first(where: { $0.isMediaPlaying }),
           next == nil || !(next!.isMediaPlaying) {
            next = playing
        }
        next = next ?? candidates.first

        if next !== currentTab {
            currentTab = next
            tabToken = nil
            if let tab = next {
                tabToken = TabEventBus.shared.subscribe(tabID: tab.id) {
                    [weak self] event in
                    switch event.kind {
                    case .audio, .media, .favicon, .title: self?.refresh()
                    default: break
                    }
                }
            }
        }
        refresh()
    }

    /// Repaint the SwiftUI model from the current tab's live state.
    /// Each @Published write triggers an objectWillChange fan-out + SwiftUI
    /// diff, so guard every assignment — without guards a single audio
    /// event publishes 9 changes when 0 fields actually moved.
    private func refresh() {
        guard let tab = currentTab, Self.qualifies(tab) else {
            if model.hasSession { model.hasSession = false }
            return
        }
        if !model.hasSession { model.hasSession = true }
        if model.favicon !== tab.favicon { model.favicon = tab.favicon }
        let host = URL(string: tab.url)?.host ?? ""
        let title = tab.mediaTitle ?? (tab.title.isEmpty ? host : tab.title)
        if model.title != title { model.title = title }
        let artist = tab.mediaArtist ?? (tab.mediaTitle != nil ? host : nil)
        if model.artist != artist { model.artist = artist }
        let isPlaying = tab.isMediaPlaying
            || (!tab.isMediaControllable && tab.isAudible)
        if model.isPlaying != isPlaying { model.isPlaying = isPlaying }
        if model.isMuted != tab.isAudioMuted { model.isMuted = tab.isAudioMuted }
        if model.canPrev != tab.canMediaPrevTrack { model.canPrev = tab.canMediaPrevTrack }
        if model.canNext != tab.canMediaNextTrack { model.canNext = tab.canMediaNextTrack }
    }

    /// Bring the playing tab forward — switching to its space first when
    /// it lives elsewhere (same pattern as reopenTab's space-jump).
    private func jump(to tab: SephrTab) {
        if tab.spaceID != SephrSpaceManager.shared.currentSpace.id,
           let space = SephrSpaceManager.shared.spaces
               .first(where: { $0.id == tab.spaceID }) {
            SephrSpaceManager.shared.switchToSpace(space)
        }
        SephrTabModel.shared.activateTab(tab)
    }
}
