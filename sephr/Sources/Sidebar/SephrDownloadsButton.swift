import AppKit
import Combine

/// Footer chip that mirrors the active-download state. Renders an
/// arrow.down.circle icon ringed by a CAShapeLayer progress arc; pulses
/// when a new download begins (Arc-style "started" animation).
final class SephrDownloadsButton: NSView {

    var onClicked: (() -> Void)?

    private let icon = NSImageView()
    private let trackRing = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private var cancellables: Set<AnyCancellable> = []
    private var hovered = false
    private var pressed = false

    static let pointSize: CGFloat = 26
    private static let ringInset: CGFloat = 1.5
    private static let ringLineWidth: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = "Downloads"

        icon.image = NSImage(systemSymbolName: "arrow.down.circle",
                              accessibilityDescription: "Downloads")
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.contentTintColor = NSColor.secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Track ring (faint) sits behind progress ring (accent). Both
        // are added directly to the host layer so the pulse transform
        // animates them with the icon as one composed element.
        trackRing.fillColor = nil
        trackRing.strokeColor = NSColor.tertiaryLabelColor
            .withAlphaComponent(0.35).cgColor
        trackRing.lineWidth = Self.ringLineWidth
        trackRing.opacity = 0  // hidden until there's progress to show

        progressRing.fillColor = nil
        progressRing.strokeColor = NSColor.controlAccentColor.cgColor
        progressRing.lineWidth = Self.ringLineWidth
        progressRing.lineCap = .round
        progressRing.strokeEnd = 0
        progressRing.opacity = 0

        layer?.addSublayer(trackRing)
        layer?.addSublayer(progressRing)

        subscribe()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Layout

    override func layout() {
        super.layout()
        let inset = Self.ringInset + Self.ringLineWidth / 2
        let r = min(bounds.width, bounds.height) / 2 - inset
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        // Start the arc at 12 o'clock and sweep clockwise — visually
        // matches every other progress ring users have seen. In AppKit's
        // flipped y-up frame, that's startAngle = +π/2 going clockwise
        // (which here means `clockwise: true` because the layer reads
        // angles in a top-left coordinate space).
        path.addArc(
            center: center, radius: r,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: false)
        trackRing.path = path
        progressRing.path = path
        trackRing.frame = bounds
        progressRing.frame = bounds
    }

    // MARK: — Subscriptions

    private func subscribe() {
        let obs = SephrDownloadsObserver.shared

        obs.$activeProgress
            .sink { [weak self] p in self?.setProgress(CGFloat(p)) }
            .store(in: &cancellables)

        obs.$hasActive
            .sink { [weak self] active in self?.setActive(active) }
            .store(in: &cancellables)

        obs.downloadStarted
            .sink { [weak self] in self?.pulse() }
            .store(in: &cancellables)
    }

    private func setActive(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        trackRing.opacity = active ? 1 : 0
        progressRing.opacity = active ? 1 : 0
        CATransaction.commit()
        icon.contentTintColor = active
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor
    }

    private func setProgress(_ p: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut))
        progressRing.strokeEnd = max(0, min(1, p))
        CATransaction.commit()
    }

    private func pulse() {
        guard let layer = layer else { return }
        // Anchor at center for a clean scale-up. NSView layers default
        // to (0,0); we have to bump the anchor point and re-set the
        // position to keep the frame in place.
        ensureCenteredAnchor()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.32
        scale.duration = 0.18
        scale.autoreverses = true
        scale.timingFunction =
            CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "downloadStartPulse")

        // Brief tint flash so the user catches the change at a glance.
        let original = icon.contentTintColor
        icon.contentTintColor = NSColor.controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            guard let self else { return }
            let active = SephrDownloadsObserver.shared.hasActive
            self.icon.contentTintColor = active
                ? NSColor.controlAccentColor
                : (original ?? NSColor.secondaryLabelColor)
        }
    }

    private var anchorCentered = false
    private func ensureCenteredAnchor() {
        guard let layer = layer, !anchorCentered else { return }
        let oldFrame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = oldFrame  // re-apply so position absorbs the shift
        anchorCentered = true
    }

    // MARK: — Hover + click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshBackground()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshBackground()
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        refreshBackground()
        onClicked?()
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        refreshBackground()
    }

    private func refreshBackground() {
        let alpha: CGFloat = pressed ? 0.18 : (hovered ? 0.10 : 0.0)
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(alpha).cgColor
    }
}
