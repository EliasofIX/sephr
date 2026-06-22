import SwiftUI
import UIKit
import WebKit

/// Hosts the active tab's WKWebView. The web view instance is owned by
/// `WebViewPool`; this representable only mounts/unmounts it, so tab
/// switches swap views without reloading.
///
/// The container also owns the Pinch-to-Summarize gesture recogniser so
/// `BrowserEngine` doesn't have to reach into UIKit. The callback fires
/// when the user pinches in past the trigger threshold (see
/// `PinchSummarizeGesture`).
struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    let onSummarize: () -> Void

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.onSummarize = onSummarize
        container.mount(webView)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        container.onSummarize = onSummarize
        container.mount(webView)
    }

    /// Plain host whose only job is swapping the mounted web view when
    /// the active tab changes and routing the summarize pinch.
    final class ContainerView: UIView {
        private weak var current: WKWebView?

        /// Set by the representable; called when the pinch crosses the
        /// summarize threshold.
        var onSummarize: (() -> Void)?

        private lazy var summarizeGesture: PinchSummarizeGesture = {
            let gesture = PinchSummarizeGesture(target: nil, action: nil)
            gesture.onTrigger = { [weak self] in
                self?.onSummarize?()
            }
            return gesture
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(summarizeGesture)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            addGestureRecognizer(summarizeGesture)
        }

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
