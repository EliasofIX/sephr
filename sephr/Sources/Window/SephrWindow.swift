import AppKit

/// Custom NSWindow: full-bleed, transparent titlebar, drag from anywhere in
/// the top 52pt band, rounded corners inherited from the system.
final class SephrWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func awakeFromNib() {
        super.awakeFromNib()
        isMovableByWindowBackground = false
    }

    override func mouseDown(with event: NSEvent) {
        // Allow dragging from any non-interactive area in the titlebar band.
        let loc = event.locationInWindow
        let hit = contentView?.hitTest(loc)
        if loc.y > frame.height - 52, hit === contentView {
            performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}
