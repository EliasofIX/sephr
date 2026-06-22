import AppKit

/// Borderless icon NSButton with subtle hover + press background tints.
/// Base class for every chrome-style button in the sidebar. Subclasses
/// (toggle, nav, close, disclosure, plus, …) just configure the symbol
/// image / corner radius / tint color; the tracking-area + state
/// machinery lives here so the look-and-feel stays uniform across the
/// whole sidebar.
///
/// Tints are blended white over whatever Liquid Glass material sits
/// underneath — opacity, not color, drives the interaction read.
class SephrHoverButton: NSButton {

    var restAlpha:  CGFloat = 0.0
    var hoverAlpha: CGFloat = 0.10
    var pressAlpha: CGFloat = 0.18

    private var hovered = false {
        didSet { if hovered != oldValue { refreshBackground() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        refreshBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }

    /// NSControl's `mouseDown(with:)` runs its own tracking loop until
    /// the user releases — sandwich a press tint around the super call
    /// so the button reads as "held" for the click duration. On return,
    /// fall back to the hover / rest tint depending on where the cursor
    /// ended up.
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(pressAlpha).cgColor
        super.mouseDown(with: event)
        refreshBackground()
    }

    private func refreshBackground() {
        let a = hovered ? hoverAlpha : restAlpha
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(a).cgColor
    }
}
