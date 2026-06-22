import AppKit

/// Thin shine-bar pinned to the top of the content area. A horizontal
/// gradient sweeps across the layer while loading, and the whole bar
/// pulses opacity for a soft "alive" feel. Hidden when idle. Matches
/// the DC monochrome language — no hue, only value + motion.
///
/// Two refinements over the original:
///   1. A short show-delay (80 ms) absorbs sub-perception loads so the
///      bar doesn't pop on-and-off for cached pages — easily the most
///      common "loading" case in normal browsing.
///   2. Reduce Motion suppresses the shine + pulse animations and shows
///      a calm static bar instead, in line with the system-wide setting.
final class SephrLoadingBar: NSView {

    static let height: CGFloat = 2.5

    private let shine = CAGradientLayer()
    /// Tri-state: what *should* be true, vs what the layer is currently
    /// drawing. The delta is what the show-delay debounce squashes.
    private var desiredLoading = false
    private var isAnimating = false
    private var showWorkItem: DispatchWorkItem?

    /// AppKit accessibility setting; recomputed on each setLoading call.
    /// NSWorkspace fires a notification when the user flips it, but for
    /// a bar that only animates while a page is loading we can just
    /// re-read it at each transition without a subscription.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Show this load only if it persists past this much wall time. 80ms
    /// is below interactive perception but above the duration of a
    /// cached-page "loading" flicker, so the bar shows only for genuinely
    /// in-flight loads.
    private static let showDelay: TimeInterval = 0.08

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Faint base tint so the bar is visible against the dark
        // content backdrop even when the shine sweep is at its edges.
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.06).cgColor

        shine.frame = bounds
        shine.colors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        shine.locations = [0.0, 0.5, 1.0]
        shine.startPoint = CGPoint(x: -0.3, y: 0.5)
        shine.endPoint   = CGPoint(x:  0.0, y: 0.5)
        layer?.addSublayer(shine)

        alphaValue = 0  // hidden until setLoading(true)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shine.frame = bounds
    }

    /// Show or hide the bar with a quick crossfade. Starts/stops the
    /// shine animation so the layer doesn't burn frames when idle.
    /// Sub-80ms loads (cached pages, redirects) never see the bar at
    /// all thanks to the show-delay debounce.
    func setLoading(_ loading: Bool) {
        guard loading != desiredLoading else { return }
        desiredLoading = loading

        if loading {
            // Defer the actual show by `showDelay` — a quick load that
            // finishes before the delay fires never animates the bar in.
            showWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.desiredLoading else { return }
                self.actuallyShow()
            }
            showWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.showDelay, execute: work)
        } else {
            showWorkItem?.cancel()
            showWorkItem = nil
            // If we never actually showed (load finished within the
            // delay window), don't animate the hide either.
            guard isAnimating else { return }
            actuallyHide()
        }
    }

    private func actuallyShow() {
        guard !isAnimating else { return }
        isAnimating = true

        // Honor Reduce Motion: skip the shine + pulse, just show a
        // calm static bar at midpoint opacity. The fade-in itself
        // stays — AppKit treats simple opacity transitions as
        // accessibility-safe.
        if !reduceMotion {
            startShineAnimation()
            startPulseAnimation()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = reduceMotion ? 0.7 : 1
        }
    }

    private func actuallyHide() {
        isAnimating = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // If a new load came in mid-fade-out, leave the animations
            // running — the next show() call will redrive the fade-in
            // from whatever alpha we landed on.
            guard let self, !self.isAnimating else { return }
            self.stopAnimations()
        })
    }

    private func startShineAnimation() {
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = NSValue(point: CGPoint(x: -0.3, y: 0.5))
        start.toValue   = NSValue(point: CGPoint(x:  1.0, y: 0.5))
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = NSValue(point: CGPoint(x: 0.0, y: 0.5))
        end.toValue   = NSValue(point: CGPoint(x: 1.3, y: 0.5))

        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = 1.3
        group.repeatCount = .infinity
        group.timingFunction =
            CAMediaTimingFunction(name: .easeInEaseOut)
        shine.add(group, forKey: "shine")
    }

    private func startPulseAnimation() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.7
        pulse.toValue   = 1.0
        pulse.duration  = 0.9
        pulse.autoreverses = true
        pulse.repeatCount  = .infinity
        pulse.timingFunction =
            CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }

    private func stopAnimations() {
        shine.removeAnimation(forKey: "shine")
        layer?.removeAnimation(forKey: "pulse")
    }
}
