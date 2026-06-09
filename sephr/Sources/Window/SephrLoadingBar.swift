import AppKit

/// Thin shine-bar pinned to the top of the content area. A horizontal
/// gradient sweeps across the layer while loading, and the whole bar
/// pulses opacity for a soft "alive" feel. Hidden when idle. Matches
/// the DC monochrome language — no hue, only value + motion.
final class SephrLoadingBar: NSView {

    static let height: CGFloat = 2.5

    private let shine = CAGradientLayer()
    private var isAnimating = false

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
    func setLoading(_ loading: Bool) {
        guard loading != isAnimating else { return }
        isAnimating = loading
        if loading {
            startShineAnimation()
            startPulseAnimation()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isAnimating else { return }
                self.stopAnimations()
            })
        }
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
