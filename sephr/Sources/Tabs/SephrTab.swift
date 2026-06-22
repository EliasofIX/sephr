import AppKit
import CAL
import SephrKit

/// A single tab, owned by SephrTabModel. The CALWebView is lazily created
/// on first display and held weakly by the window controller.
final class SephrTab: Codable, Identifiable {

    /// What the tab shows when activated. `.web` hosts a CALWebView;
    /// `.note` hosts the native SephrNoteCanvas (Arc-easel-style
    /// freeform canvas) and never creates a WebContents.
    enum Kind: String, Codable {
        case web
        case note
    }

    let id: UUID
    let kind: Kind
    var url: String
    var title: String
    var spaceID: UUID
    var folderID: UUID?
    var isPinned: Bool
    var isActive: Bool
    var isArchived: Bool
    var createdAt: Date
    var lastAccessedAt: Date

    // Runtime-only — not persisted.
    weak var folder: SephrTabFolder?
    var webView: CALWebView?
    var favicon: NSImage?
    /// Last-captured thumbnail of the tab's content. Refreshed when
    /// the user switches away from the tab (its `CALWebView` is still
    /// attached at that moment so `CopyFromSurface` succeeds). The
    /// peek popover reads this so hovering an inactive tab still
    /// shows its actual page, not just the SF-globe placeholder.
    var thumbnail: NSImage?
    /// True while the tab's WebContents is between DidStartLoading and
    /// DidStopLoading. Drives the top-of-page loading indicator.
    var isLoading: Bool = false
    /// True while the tab's page is emitting audio (Chromium's
    /// OnAudioStateChanged). Drives the sidebar's audio indicator. Stays
    /// true while muted media plays — muting silences output, it doesn't
    /// stop the page producing audio.
    var isAudible: Bool = false
    /// True while the tab's audio output is muted (per-tab mute toggle).
    /// Controls the indicator's glyph (speaker vs. speaker-slash).
    var isAudioMuted: Bool = false
    /// Destination of the link currently under the pointer in this tab's
    /// page, or nil when the cursor isn't over a link. Updated live from
    /// Chromium's UpdateTargetURL. The window controller reads this on a
    /// Shift keypress to decide what the link-peek overlay should preview.
    var hoveredLinkURL: String?

    init(id: UUID = UUID(),
         kind: Kind = .web,
         url: String,
         title: String = "",
         spaceID: UUID,
         folderID: UUID? = nil,
         isPinned: Bool = false,
         isActive: Bool = false,
         isArchived: Bool = false,
         createdAt: Date = Date(),
         lastAccessedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.spaceID = spaceID
        self.folderID = folderID
        self.isPinned = isPinned
        self.isActive = isActive
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        // Surface any cached favicon for this URL so a brand-new tab
        // that points at a familiar host renders the right icon
        // immediately. The cache is a no-op for never-visited hosts.
        // Note tabs have no URL — their cell renders a fixed glyph.
        guard kind == .web else { return }
        self.favicon = SephrFaviconCache.shared.cached(for: url)
        // Memory hit means we already have the icon — skip the disk hop
        // and its main-thread round-trip entirely.
        if self.favicon != nil { return }
        // Disk lookup off the init path; the cell repaints via the
        // favicon event.
        SephrFaviconCache.shared.load(for: url) { [weak self] image in
            guard let self, let image, self.favicon == nil else { return }
            self.favicon = image
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .favicon))
        }
    }

    // MARK: - Codable (exclude runtime members)

    enum CodingKeys: String, CodingKey {
        case id, kind, url, title, spaceID, folderID
        case isPinned, isActive, isArchived
        case createdAt, lastAccessedAt
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id      = try c.decode(UUID.self,   forKey: .id)
        // Sessions written before the Notes feature have no kind —
        // every pre-existing tab is a web tab.
        self.kind    = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .web
        self.url     = try c.decode(String.self, forKey: .url)
        self.title   = try c.decode(String.self, forKey: .title)
        self.spaceID = try c.decode(UUID.self,   forKey: .spaceID)
        self.folderID = try c.decodeIfPresent(UUID.self,
                                              forKey: .folderID)
        self.isPinned   = try c.decode(Bool.self, forKey: .isPinned)
        self.isActive   = try c.decode(Bool.self, forKey: .isActive)
        self.isArchived = try c.decode(Bool.self, forKey: .isArchived)
        self.createdAt  = try c.decode(Date.self, forKey: .createdAt)
        self.lastAccessedAt = try c.decode(Date.self,
                                            forKey: .lastAccessedAt)
        guard kind == .web else { return }
        // Restore favicon from the disk-backed cache. Memory hit is
        // free; the disk read happens off the decode path so session
        // restore isn't 40+ serial Data(contentsOf:) calls. The cell
        // repaints via the favicon event when the icon arrives. (The
        // completion hops to main; decode finishes long before disk IO
        // returns, so the favicon read/write below doesn't race init.)
        self.favicon = SephrFaviconCache.shared.cached(for: self.url)
        if self.favicon != nil { return }
        SephrFaviconCache.shared.load(for: self.url) { [weak self] image in
            guard let self, let image, self.favicon == nil else { return }
            self.favicon = image
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .favicon))
        }
    }

    // MARK: - WebView lifecycle

    @MainActor
    func getOrCreateWebView() -> CALWebView {
        // Note tabs host a native canvas — every display/warm call site
        // branches on `kind` before reaching here. Creating a WebContents
        // for one would waste a renderer on a tab that can never show it.
        assert(kind == .web, "getOrCreateWebView called on a note tab")
        if let wv = webView { return wv }
        let profile = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == spaceID })?
            .profileID ?? "default"
        let url = URL(string: self.url) ?? URL(string: "about:blank")!
        let wv = CALWebView(url: url, profile: profile)
        wv.onNavigation = { [weak self] (url: String, title: String) in
            guard let self else { return }
            let urlChanged = self.url != url
            let newTitle = title.isEmpty ? self.title : title
            let titleChanged = self.title != newTitle
            // Bail when Chromium re-fired the same URL+title (common on
            // SPA pushState that doesn't change the entry, on focus
            // restoration, and on history-API in-page updates).
            guard urlChanged || titleChanged else { return }
            if urlChanged { self.url = url }
            if titleChanged { self.title = newTitle }
            // Persist so the new URL survives a relaunch — without
            // this the session file keeps the URL the tab was created
            // with, never what the user actually navigated to.
            SephrTabModel.shared.persist()
            if urlChanged {
                TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .url))
            }
            if titleChanged {
                TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .title))
            }
        }
        wv.onFavicon = { [weak self] (image: NSImage?) in
            guard let self else { return }
            // Same NSImage instance arriving twice (Chromium re-fires the
            // PNG bytes on certain navigations); skip the cache write + bus
            // post when nothing actually changed.
            if self.favicon === image { return }
            self.favicon = image
            if let image {
                // Persist so future tabs at this host don't have to
                // wait for Chromium to re-download.
                SephrFaviconCache.shared.set(image, for: self.url)
            }
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .favicon))
        }
        wv.onLoading = { [weak self] (loading: Bool, _: Double) in
            guard let self, self.isLoading != loading else { return }
            // Guard against same-value re-fires: Chromium emits the
            // callback on every load-progress tick as well as start/stop;
            // we only care about transitions for the loading bar +
            // sidebar fade. Without the guard, the bar's CALayer animation
            // restarts on every tick of a slow page.
            self.isLoading = loading
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .loading))
            NotificationCenter.default.post(
                name: .sephrTabLoadingChanged, object: self)
        }
        wv.onNewTabRequest = { [weak self] (url: String) in
            // Right-click → "Open Link in New Tab" — Chromium fired the
            // request from the in-page context menu; spawn a real
            // SephrTab in the same space.
            guard let self else { return }
            let space = SephrSpaceManager.shared.spaces
                .first(where: { $0.id == self.spaceID })
                ?? SephrSpaceManager.shared.currentSpace
            _ = SephrTabModel.shared.newTab(in: space, url: url)
        }
        wv.onTargetURLChange = { [weak self] (url: String?) in
            // Mirror Chromium's hovered-link status text. nil when the
            // cursor leaves a link. Read on Shift to summon the link peek.
            self?.hoveredLinkURL = url
        }
        wv.onPopupRequest = { (popupView: CALWebView) in
            // window.open popup (e.g. "Continue with Google"). Surface it in
            // a peek over the page; the key window presents it. No `self`
            // capture — the popup view's lifetime is owned by the peek.
            NotificationCenter.default.post(
                name: .sephrPresentPopupPeek, object: popupView)
        }
        wv.onCloseRequest = { [weak self] in
            // window.close() that Chromium allowed (a script-openable tab).
            guard let self else { return }
            SephrTabModel.shared.closeTab(self)
        }
        wv.onAudioStateChange = { [weak self] (audible: Bool) in
            guard let self, self.isAudible != audible else { return }
            self.isAudible = audible
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .audio))
            // The Now Playing pill keys its visibility off audibility too
            // (pages that play sound without a Media Session API session).
            NotificationCenter.default.post(
                name: .sephrTabMediaChanged, object: self)
        }
        wv.onMediaSessionChange = { [weak self] in
            guard let self else { return }
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .media))
            NotificationCenter.default.post(
                name: .sephrTabMediaChanged, object: self)
        }
        // Seed from the live contents in case audio is already playing before
        // the first callback edge (an adopted popup, or a wake that resumed
        // media). The callback only fires on transitions, not the initial
        // state, so without this an already-audible tab shows no indicator
        // until its audio next stops and restarts.
        isAudible = wv.isAudible
        isAudioMuted = wv.isAudioMuted
        webView = wv
        return wv
    }

    // MARK: - Media session (Now Playing pill)

    /// True while the tab's page has active media the browser may control —
    /// the show signal for the sidebar's Now Playing pill. Reads the live
    /// CALWebView snapshot, so it's nil-safe for note tabs and never-warmed
    /// web tabs.
    var isMediaControllable: Bool { webView?.isMediaControllable ?? false }
    /// True while playing, false while paused/stopped.
    var isMediaPlaying: Bool { webView?.isMediaPlaying ?? false }
    /// Media Session API metadata; nil when the site publishes none
    /// (callers fall back to the tab title).
    var mediaTitle: String? { webView?.mediaTitle }
    var mediaArtist: String? { webView?.mediaArtist }
    /// True when the page registered previoustrack/nexttrack handlers.
    var canMediaPrevTrack: Bool { webView?.canMediaPrevTrack ?? false }
    var canMediaNextTrack: Bool { webView?.canMediaNextTrack ?? false }

    /// Pause when playing, resume when paused. Safe no-op without a live
    /// WebContents or active media (Chromium's MediaSession contract).
    @MainActor
    func mediaPlayPause() {
        guard let wv = webView else { return }
        wv.isMediaPlaying ? wv.mediaSuspend() : wv.mediaResume()
    }

    @MainActor
    func mediaNextTrack() { webView?.mediaNextTrack() }

    @MainActor
    func mediaPreviousTrack() { webView?.mediaPreviousTrack() }

    /// Toggle this tab's per-tab audio mute. No-op when the tab has no live
    /// WebContents (a note tab, or a web tab that's never been warmed — there
    /// is nothing playing to mute). Posts a `.audio` event so the sidebar
    /// indicator repaints its glyph.
    @MainActor
    func toggleMute() {
        guard let wv = webView else { return }
        let next = !wv.isAudioMuted
        wv.setAudioMuted(next)
        isAudioMuted = next
        TabEventBus.shared.post(TabEvent(tabID: id, kind: .audio))
    }
}
