import SwiftUI
import WebKit

/// Hosts the active tab's WKWebView. The web view instance is owned by
/// `WebViewPool`; this representable only mounts/unmounts it, so tab
/// switches swap views without reloading.
struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.mount(webView)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.mount(webView)
    }

    /// Plain host whose only job is swapping the mounted web view when
    /// the active tab changes.
    final class ContainerView: UIView {
        private weak var current: WKWebView?

        func mount(_ webView: WKWebView) {
            guard current !== webView else { return }
            current?.removeFromSuperview()
            current = webView
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
        }
    }
}
