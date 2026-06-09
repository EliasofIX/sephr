import AppKit
import CAL
import SephrKit

/// A single tab, owned by SephrTabModel. The CALWebView is lazily created
/// on first display and held weakly by the window controller.
final class SephrTab: Codable, Identifiable {

    let id: UUID
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
    /// Destination of the link currently under the pointer in this tab's
    /// page, or nil when the cursor isn't over a link. Updated live from
    /// Chromium's UpdateTargetURL. The window controller reads this on a
    /// Shift keypress to decide what the link-peek overlay should preview.
    var hoveredLinkURL: String?

    init(id: UUID = UUID(),
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
        self.favicon = SephrFaviconCache.shared.get(for: url)
    }

    // MARK: - Codable (exclude runtime members)

    enum CodingKeys: String, CodingKey {
        case id, url, title, spaceID, folderID
        case isPinned, isActive, isArchived
        case createdAt, lastAccessedAt
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id      = try c.decode(UUID.self,   forKey: .id)
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
        // Restore favicon from the disk-backed cache so the sidebar
        // shows the page's icon immediately on relaunch — without
        // this, every tab reverts to the SF-globe placeholder until
        // Chromium re-downloads the icon.
        self.favicon = SephrFaviconCache.shared.get(for: self.url)
    }

    // MARK: - WebView lifecycle

    @MainActor
    func getOrCreateWebView() -> CALWebView {
        if let wv = webView { return wv }
        let profile = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == spaceID })?
            .profileID ?? "default"
        let url = URL(string: self.url) ?? URL(string: "about:blank")!
        let wv = CALWebView(url: url, profile: profile)
        wv.onNavigation = { [weak self] (url: String, title: String) in
            guard let self else { return }
            self.url = url
            self.title = title.isEmpty ? self.title : title
            // Persist so the new URL survives a relaunch — without
            // this the session file keeps the URL the tab was created
            // with, never what the user actually navigated to.
            SephrTabModel.shared.persist()
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .url))
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .title))
            NotificationCenter.default.post(
                name: .sephrTabModelChanged, object: nil)
        }
        wv.onFavicon = { [weak self] (image: NSImage?) in
            guard let self else { return }
            self.favicon = image
            if let image {
                // Persist so future tabs at this host don't have to
                // wait for Chromium to re-download.
                SephrFaviconCache.shared.set(image, for: self.url)
            }
            TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .favicon))
            NotificationCenter.default.post(
                name: .sephrTabModelChanged, object: nil)
        }
        wv.onLoading = { [weak self] (loading: Bool, _: Double) in
            guard let self else { return }
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
        webView = wv
        return wv
    }
}
