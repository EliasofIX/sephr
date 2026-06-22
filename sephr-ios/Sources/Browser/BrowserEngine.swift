import WebKit
import Observation
import UIKit

/// Coordinates the tab store, the web view pool, and per-page navigation
/// state for the chrome (progress bar, back/forward, secure indicator).
/// One instance for the whole app.
@Observable @MainActor
final class BrowserEngine: NSObject {

    let store = TabStore()
    let pool = WebViewPool()
    let history = HistoryStore()

    /// On-device LFM2-VL-450M runtime — shared by SuperBrowse and
    /// Summarize. Lazily warms on the first feature invocation.
    let model = ModelManager()

    @ObservationIgnored
    private(set) lazy var superBrowseEngine = SuperBrowseEngine(model: model)

    @ObservationIgnored
    private(set) lazy var summarizeEngine = SummarizeEngine(model: model)

    /// When non-nil, the SuperBrowse hero / result view is mounted over
    /// the browser. `BrowserShell` observes this and shows the overlay.
    var superBrowseSession: SuperBrowseSession?

    /// Same idea for Summarize. Mutually exclusive with the above —
    /// starting one cancels the other.
    var summarizeSession: SummarizeSession?

    // Live state of the *active* tab's web view, mirrored for SwiftUI.
    private(set) var estimatedProgress: Double = 1
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var currentURL: URL?
    private(set) var hasSecureContent = true

    /// Auto-collapse state for the bottom bar: scrolling down on the page
    /// hides the chrome so the content can breathe; scrolling back up (or
    /// reaching the top, or navigating) brings it back. The BottomBar also
    /// writes this directly when the user pulls it down or up by hand.
    var isBarCollapsed = false

    /// Set when a page wants to open a new window (target=_blank) — the
    /// UI responds by opening it as a fresh tab.
    var pendingPopupURL: URL?

    /// Tabs the user flipped to "Request Desktop Site".
    private(set) var desktopTabs: Set<UUID> = []

    private var observations: [NSKeyValueObservation] = []
    private var observedView: WKWebView?
    private var lastScrollY: CGFloat = 0
    private var scrollAccum: CGFloat = 0

    override init() {
        super.init()
        syncActiveWebView()
        Task { [pool] in
            if let list = await ContentBlocker.ruleList() {
                pool.install(ruleList: list)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pool.trim(keeping: self.store.activeTabID)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.autoArchive() }
        }
    }

    // MARK: — Active web view

    /// Wire delegates and KVO for the active tab. Call from lifecycle
    /// hooks — never from SwiftUI `body` (mutates observable state).
    func syncActiveWebView() {
        _ = activeWebView
    }

    /// The active tab's live web view, creating (and lazily loading) it if
    /// needed. Returns nil when there is no active tab (deck is empty).
    var activeWebView: WKWebView? {
        guard let tab = store.activeTab else {
            attach(to: nil)
            return nil
        }
        let view = pool.view(for: tab)
        view.navigationDelegate = self
        view.uiDelegate = self
        attach(to: view)
        return view
    }

    /// Re-point KVO at the view backing the active tab.
    private func attach(to view: WKWebView?) {
        guard view !== observedView else { return }
        observations = []
        observedView = view
        scrollAccum = 0
        guard let view else {
            estimatedProgress = 1; isLoading = false
            canGoBack = false; canGoForward = false
            currentURL = nil
            isBarCollapsed = false
            return
        }
        currentURL = view.url
        isLoading = view.isLoading
        estimatedProgress = view.isLoading ? view.estimatedProgress : 1
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        lastScrollY = view.scrollView.contentOffset.y
        // New tab → fresh chrome.
        isBarCollapsed = false

        observations = [
            view.observe(\.estimatedProgress) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = v.estimatedProgress }
            },
            view.observe(\.isLoading) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.isLoading = v.isLoading }
            },
            view.observe(\.canGoBack) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoBack = v.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoForward = v.canGoForward }
            },
            view.observe(\.url) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentURL = v.url
                    if let id = self.store.activeTabID {
                        self.store.touch(id, url: v.url)
                    }
                }
            },
            view.observe(\.title) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    guard let self, let id = self.store.activeTabID else { return }
                    self.store.touch(id, title: v.title ?? "")
                }
            },
            view.observe(\.hasOnlySecureContent) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.hasSecureContent = v.hasOnlySecureContent }
            },
            view.scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] sv, _ in
                MainActor.assumeIsolated { self?.handleWebScroll(sv) }
            },
        ]
    }

    /// Translate web-view scrolling into bottom-bar collapse state. Drag
    /// past the top of the page or scroll-up over the threshold expands
    /// the chrome; scroll-down over the threshold collapses it. Pages
    /// shorter than the viewport stay expanded.
    private func handleWebScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        let dy = y - lastScrollY
        lastScrollY = y

        // Within the rubber-band region at the top: always show the bar.
        if y <= 8 {
            scrollAccum = 0
            if isBarCollapsed { isBarCollapsed = false }
            return
        }
        // Page not actually scrollable (or hasn't laid out yet): leave the
        // bar alone — there's nothing to collapse for.
        if scrollView.contentSize.height <= scrollView.bounds.height + 8 {
            scrollAccum = 0
            if isBarCollapsed { isBarCollapsed = false }
            return
        }
        // Reverse direction → restart the accumulator so a small bounce
        // back the other way doesn't immediately flip the bar.
        if (dy > 0) != (scrollAccum > 0) { scrollAccum = 0 }
        scrollAccum += dy

        let threshold: CGFloat = 60
        if scrollAccum > threshold {
            if !isBarCollapsed { isBarCollapsed = true }
            scrollAccum = 0
        } else if scrollAccum < -threshold {
            if isBarCollapsed { isBarCollapsed = false }
            scrollAccum = 0
        }
    }

    // MARK: — Commands

    /// Open the search-bar submission: a URL if it parses as one,
    /// otherwise a search query.
    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URLBuilder.url(from: trimmed) else { return }
        open(url)
    }

    /// Load a URL in the active tab, creating one if the deck is empty.
    func open(_ url: URL) {
        if store.activeTab == nil { store.newTab() }
        guard let tab = store.activeTab else { return }
        store.touch(tab.id, url: url)
        pool.view(for: tab).load(URLRequest(url: url))
        _ = activeWebView   // re-attach KVO
    }

    /// New tab + immediately load. Reuses the active tab when it's still
    /// blank so dismiss-without-typing doesn't leave a pile of empties.
    func openInNewTab(_ url: URL, incognito: Bool = false) {
        snapshotActiveTab()
        if let tab = store.activeTab, !tab.hasBrowsableURL,
           tab.isIncognito == incognito {
            store.touch(tab.id, url: url)
            pool.view(for: tab).load(URLRequest(url: url))
            _ = activeWebView
            return
        }
        let tab = store.newTab(url: url, incognito: incognito)
        _ = pool.view(for: tab)
        _ = activeWebView
    }

    func goBack()    { observedView?.goBack() }
    func goForward() { observedView?.goForward() }
    func reload()    { observedView?.reload() }
    func stop()      { observedView?.stopLoading() }

    var activeTabIsDesktop: Bool {
        guard let id = store.activeTabID else { return false }
        return desktopTabs.contains(id)
    }

    func toggleDesktopSite() {
        guard let id = store.activeTabID else { return }
        if desktopTabs.contains(id) { desktopTabs.remove(id) }
        else { desktopTabs.insert(id) }
        observedView?.reload()
    }

    func presentFindInPage() {
        observedView?.findInteraction?
            .presentFindNavigator(showingReplace: false)
    }

    var pageZoom: CGFloat {
        get { observedView?.pageZoom ?? 1 }
        set { observedView?.pageZoom = newValue }
    }

    func switchTo(_ id: UUID) {
        guard id != store.activeTabID else { return }
        snapshotActiveTab()
        store.activate(id)
        _ = activeWebView
    }

    /// Relative tab switching for edge-swipes on the bar (−1 = left).
    func switchRelative(_ delta: Int) {
        let live = store.liveTabs
        guard live.count > 1,
              let idx = live.firstIndex(where: { $0.id == store.activeTabID })
        else { return }
        let next = (idx + delta + live.count) % live.count
        switchTo(live[next].id)
    }

    func archiveActiveTab() {
        guard let id = store.activeTabID else { return }
        snapshotActiveTab()
        pool.tearDown(id)
        store.archive(id)
        _ = activeWebView
    }

    /// Capture the active tab's pixels for its deck card before it goes
    /// off-screen.
    func snapshotActiveTab() {
        guard let id = store.activeTabID,
              let view = pool.existingView(for: id),
              view.window != nil,
              let tab = store.activeTab else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let incognito = tab.isIncognito
        view.takeSnapshot(with: config) { image, _ in
            guard let image else { return }
            TabSnapshotCache.shared.store(image, for: id,
                                          persistToDisk: !incognito)
        }
    }

    // MARK: — SuperBrowse + Summarize

    /// Kick off a SuperBrowse query. Tears down any in-flight session
    /// first. The hero mounts as soon as `superBrowseSession` becomes
    /// non-nil; the result view takes over once the model starts
    /// generating.
    func startSuperBrowse(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismissSummarize()
        superBrowseSession = superBrowseEngine.start(question: trimmed)
    }

    /// Cancel + dismiss SuperBrowse — called from the hero/result close
    /// buttons or when another modal takes priority.
    func dismissSuperBrowse() {
        superBrowseEngine.cancel()
        superBrowseSession = nil
    }

    /// Snapshot the live page, kick off the Summarize pipeline, mount
    /// the origami overlay. Returns immediately so the gesture handler
    /// stays responsive.
    func startSummarize() {
        Task { [weak self] in
            guard let self else { return }
            guard let tab = self.store.activeTab,
                  let view = self.pool.existingView(for: tab.id),
                  view.window != nil else { return }
            guard let snapshot = await self.captureSnapshot(for: view) else {
                return
            }
            self.dismissSuperBrowse()
            self.summarizeSession = self.summarizeEngine.start(
                webView: view,
                pageTitle: tab.displayTitle,
                host: tab.url?.host() ?? "",
                pageURL: tab.url,
                snapshot: snapshot)
        }
    }

    func dismissSummarize() {
        summarizeEngine.cancel()
        summarizeSession = nil
    }

    /// Async snapshot helper used by Summarize — distinct from the
    /// fire-and-forget `snapshotActiveTab()` that just feeds the deck
    /// thumbnail cache.
    private func captureSnapshot(for view: WKWebView) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: — WKNavigationDelegate

extension BrowserEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences)
        async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Hand non-web schemes (mailto:, tel:, app links) to the system.
        if let url = action.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            await UIApplication.shared.open(url)
            return (.cancel, preferences)
        }
        if let id = store.activeTabID, desktopTabs.contains(id) {
            preferences.preferredContentMode = .desktop
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url,
              let tab = store.activeTab,
              pool.existingView(for: tab.id) === webView,
              !tab.isIncognito else { return }
        history.record(url: url, title: webView.title ?? "")
    }
}

// MARK: — WKUIDelegate

extension BrowserEngine: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank → open as a new Sephr tab instead of a popup.
        if let url = action.request.url {
            pendingPopupURL = url
        }
        return nil
    }
}
