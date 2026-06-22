import WebKit

/// A scratch pool of WKWebViews that are never mounted to a view
/// hierarchy. Used by SuperBrowse to load the SERP and the top-N result
/// pages in the background, so the visible tab is untouched.
///
/// Each fetch is one-shot: create → load → wait → extract → tear down.
/// Cookies and storage are isolated per-fleet via `.nonPersistent()` —
/// SuperBrowse never pollutes the user's browsing data store.
@MainActor
final class HiddenWebViewFleet {

    /// Desktop Safari UA so article pages serve their full content
    /// instead of mobile/AMP variants. NO product token suffix — DDG and
    /// some publishers treat anything but a vanilla Safari UA as a bot
    /// and serve an empty / consent-wall page.
    private static let desktopUserAgent: String =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.6 Safari/605.1.15"

    /// Outcome of a single hidden fetch.
    enum Outcome {
        case loaded(WKWebView)
        case timedOut
        case failed(Error)
    }

    /// Per-page timeout — we don't want a stuck request to block the
    /// whole fan-out.
    private let timeout: Duration

    init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }

    /// Drive one WKWebView through `load → didFinish`, with a timeout.
    /// Returns the loaded view (caller does the JS extraction) or an
    /// error / timeout. The view is always torn down by the caller.
    func fetch(_ url: URL) async -> Outcome {
        let coordinator = LoadCoordinator()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.navigationDelegate = coordinator
        webView.load(URLRequest(url: url, cachePolicy:
            .reloadIgnoringLocalCacheData, timeoutInterval: 10))

        let outcome: Outcome
        do {
            outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    await coordinator.wait()
                }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }
                guard let first = try await group.next() else {
                    return .timedOut
                }
                group.cancelAll()
                return first
            }
        } catch {
            outcome = .failed(error)
        }

        switch outcome {
        case .loaded:
            return .loaded(webView)
        case .timedOut, .failed:
            webView.stopLoading()
            webView.navigationDelegate = nil
            return outcome
        }
    }

    /// Bridges WKNavigationDelegate's callback-based API into an async
    /// continuation. One-shot — the first didFinish/didFail resolves it.
    private final class LoadCoordinator: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var resolved = false

        func wait() async -> Outcome {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        private func resolve(_ outcome: Outcome) {
            guard !resolved else { return }
            resolved = true
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            resolve(.loaded(webView))
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            resolve(.failed(error))
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            resolve(.failed(error))
        }
    }
}
