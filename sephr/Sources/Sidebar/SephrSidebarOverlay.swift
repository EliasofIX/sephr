import AppKit

/// Invisible vertical strip pinned to the window's leading edge. Reports
/// pointer enter / exit so the window controller can summon the Arc-style
/// floating sidebar overlay when the user nudges the cursor against the
/// edge. hitTest returns nil so clicks pass straight through to the page.
final class SephrSidebarHoverEdge: NSView {

    var onMouseEntered: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
}

/// Floating Arc-style sidebar shown while the main sidebar is collapsed
/// and the user hovers the leading edge. Wraps a fresh `SephrSidebarView`
/// in a Liquid Glass card with a soft shadow. The overlay self-dismisses
/// when the pointer leaves its bounds.
final class SephrFloatingSidebar: NSView {

    let sidebar: SephrSidebarView
    var onPointerExit: (() -> Void)?

    init(delegate: SephrSidebarViewDelegate) {
        self.sidebar = SephrSidebarView(asOverlay: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Drop-shadow for the floating card. The shadow lives on the
        // container's layer so it isn't clipped by the glass view's
        // rounded mask. `shadowPath` is set in layout() — without it
        // Core Animation has to rasterize the full shadow every frame,
        // which makes the slide-in/out animation hitch.
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 22
        layer?.shadowOffset = .zero

        let backdrop: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.cornerRadius = 14
            glass.tintColor = nil
            backdrop = glass
        } else {
            let v = NSVisualEffectView(frame: .zero)
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 14
            v.layer?.masksToBounds = true
            backdrop = v
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        sidebar.delegate = delegate
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Cache the shadow path so Core Animation doesn't have to
        // rasterize a 22pt blur every frame during the slide animation.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // Guard against the spurious exit AppKit fires when a subview
        // becomes first responder mid-track. If the cursor is still
        // inside our bounds, ignore.
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { return }
        onPointerExit?()
    }

    // Pure CALayer animations driven by a single CATransaction so that
    // opacity and transform share an animation engine and don't desync.
    // Mixing `animator().alphaValue` with a raw `layer.transform =` (as
    // the previous implementation did) had each property pick up a
    // different duration / timing curve — the visible effect was a
    // choppy slide-out where the fade finished before the translation.
    private static let offscreenTranslation =
        CATransform3DMakeTranslation(-24, 0, 0)

    func slideIn() {
        guard let layer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = Self.offscreenTranslation
        layer.opacity = 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut))
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    func slideOut(completion: @escaping () -> Void) {
        guard let layer = layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock(completion)
        layer.transform = Self.offscreenTranslation
        layer.opacity = 0
        CATransaction.commit()
    }
}
