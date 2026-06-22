import WebKit

/// Live WKWebViews, keyed by tab id. The pool is the efficiency core of
/// the app: only the active tab plus a small LRU of recently used tabs
/// keep a live web view (renderer process, JS heap, layer tree). Every
/// other tab is just a `SephrTab` struct and a snapshot JPEG — switching
/// back recreates the web view and reloads its URL.
@MainActor
final class WebViewPool {

    /// Active tab + two warm recents. Beyond that, the oldest web view is
    /// torn down (its tab keeps url/title/snapshot, so nothing is lost
    /// but renderer state).
    private let capacity = 3

    private var views: [UUID: WKWebView] = [:]
    private var lru: [UUID] = []

    /// Compiled blocklist, applied to every page's content controller
    /// while blocking is enabled.
    private var ruleList: WKContentRuleList?
    private var blockingEnabled =
        UserDefaults.standard.object(forKey: "contentBlocking") == nil
        || UserDefaults.standard.bool(forKey: "contentBlocking")

    func install(ruleList: WKContentRuleList) {
        self.ruleList = ruleList
        guard blockingEnabled else { return }
        regularConfiguration.userContentController.add(ruleList)
        for view in views.values {
            view.configuration.userContentController.add(ruleList)
        }
    }

    func setContentBlocking(_ enabled: Bool) {
        blockingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "contentBlocking")
        guard let ruleList else { return }
        let controllers = [regularConfiguration.userContentController]
            + views.values.map(\.configuration.userContentController)
        for controller in Set(controllers) {
            if enabled { controller.add(ruleList) }
            else { controller.remove(ruleList) }
        }
        for view in views.values { view.reload() }
    }

    /// One shared configuration so every regular tab shares a process
    /// pool, cookie store, and content-blocker rules.
    private lazy var regularConfiguration = makeConfiguration(incognito: false)

    private func makeConfiguration(incognito: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = incognito ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = true
        config.upgradeKnownHostsToHTTPS = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return config
    }

    func view(for tab: SephrTab) -> WKWebView {
        if let existing = views[tab.id] {
            markUsed(tab.id)
            return existing
        }

        let config = tab.isIncognito
            ? makeConfiguration(incognito: true) : regularConfiguration
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.isOpaque = true
        webView.backgroundColor = fieldColor
        webView.scrollView.backgroundColor = fieldColor
        webView.underPageBackgroundColor = fieldColor
        webView.customUserAgent = Self.userAgent

        views[tab.id] = webView
        markUsed(tab.id)

        if let url = tab.url, tab.hasBrowsableURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func existingView(for id: UUID) -> WKWebView? { views[id] }

    /// Matches `DC.Ink.field` light — the web view's idle backdrop.
    private var fieldColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.039, green: 0.047, blue: 0.059, alpha: 1)
                : UIColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1)
        }
    }

    private func markUsed(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
        while lru.count > capacity {
            let evicted = lru.removeFirst()
            tearDown(evicted)
        }
    }

    func tearDown(_ id: UUID) {
        guard let view = views.removeValue(forKey: id) else { return }
        lru.removeAll { $0 == id }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    /// Under memory pressure, keep only the active tab's view alive.
    func trim(keeping activeID: UUID?) {
        for id in views.keys where id != activeID {
            tearDown(id)
        }
    }

    /// Safari-like mobile UA so sites serve their mobile layouts, with the
    /// Sephr product token appended.
    private static let userAgent: String = {
        let base = UIDevice.current.userInterfaceIdiom == .pad
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
              + "Version/26.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
              + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
              + "Version/26.0 Mobile/15E148 Safari/604.1"
        return base + " Sephr/0.1"
    }()
}
