import WebKit
import Observation

/// Coordinates the tab store, the web view pool, and per-page navigation
/// state for the chrome (progress bar, back/forward, secure indicator).
/// One instance for the whole app.
@Observable @MainActor
final class BrowserEngine: NSObject {

    let store = TabStore()
    let pool = WebViewPool()
    let history = HistoryStore()

    // Live state of the *active* tab's web view, mirrored for SwiftUI.
    private(set) var estimatedProgress: Double = 1
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var currentURL: URL?
    private(set) var hasSecureContent = true

    /// Set when a page wants to open a new window (target=_blank) — the
    /// UI responds by opening it as a fresh tab.
    var pendingPopupURL: URL?

    /// Tabs the user flipped to "Request Desktop Site".
    private(set) var desktopTabs: Set<UUID> = []

    private var observations: [NSKeyValueObservation] = []
    private var observedView: WKWebView?

    override init() {
        super.init()
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
        guard let view else {
            estimatedProgress = 1; isLoading = false
            canGoBack = false; canGoForward = false
            currentURL = nil
            return
        }
        currentURL = view.url
        isLoading = view.isLoading
        estimatedProgress = view.isLoading ? view.estimatedProgress : 1
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward

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
        ]
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

    /// New tab + immediately load.
    func openInNewTab(_ url: URL, incognito: Bool = false) {
        snapshotActiveTab()
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
