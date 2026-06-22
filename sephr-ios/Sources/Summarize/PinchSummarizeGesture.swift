import UIKit

/// Recognises a deliberate two-finger pinch-IN past a threshold — the
/// "zoom out hard" gesture Arc uses for Pinch to Summarize. We layer it
/// alongside WKWebView's built-in pinch (which handles ordinary text
/// zoom) so an incidental zoom doesn't fire Summarize; only a strong,
/// fast pinch crosses the trigger.
final class PinchSummarizeGesture: UIPinchGestureRecognizer,
                                    UIGestureRecognizerDelegate {

    /// Scale at which we consider "the user clearly pinched in." A scale
    /// of 1.0 means no pinch; <1.0 is pinch-in. Going below 0.55 is well
    /// past ordinary zoom-out.
    var scaleThreshold: CGFloat = 0.55

    /// Pinch must be quick — velocity is the rate of scale change. A
    /// strong inward pinch is in the −1.5 ⋯ −5 range; gentle zoom-out is
    /// usually shallower. Combining threshold + velocity keeps the
    /// trigger rare.
    var velocityThreshold: CGFloat = -1.4

    /// Called once per gesture lifecycle when the threshold is crossed.
    /// We reset on each new pinch so the recognizer can fire again next
    /// time.
    var onTrigger: (() -> Void)?

    private var hasFired = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        addTarget(self, action: #selector(handle(_:)))
    }

    @objc private func handle(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            hasFired = false
        case .changed:
            guard !hasFired else { return }
            if recognizer.scale <= scaleThreshold,
               recognizer.velocity <= velocityThreshold {
                hasFired = true
                // Hop one runloop turn so we never invoke UIKit-mutating
                // overlay work *from inside* the recognizer's own callback.
                // Synchronously toggling `isEnabled` here (the obvious way
                // to cancel) makes UIKit assert mid-pinch.
                let trigger = onTrigger
                DispatchQueue.main.async { trigger?() }
            }
        case .ended, .cancelled, .failed:
            hasFired = false
        default:
            break
        }
    }

    // MARK: — UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Let WKWebView's pinch handle ordinary zoom; we only intercept
        // past the threshold.
        true
    }
}
