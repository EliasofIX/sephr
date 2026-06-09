import AppKit

/// Narrow vertical strip pinned over the sidebar's trailing edge. Shows a
/// horizontal-resize cursor on hover and reports live drag deltas so the
/// window controller can update the sidebar width constraint without
/// going through Auto Layout animation.
final class SephrSidebarResizer: NSView {

    /// Hit-area width. Wider than the visible hairline so the cursor can
    /// grab it comfortably without pixel-perfect aim.
    static let hitWidth: CGFloat = 8

    /// Called on mouseDown so the controller can snapshot the current
    /// sidebar width — subsequent `onDragChanged` deltas are relative to
    /// that snapshot.
    var onDragBegan: (() -> Void)?

    /// Called for each drag event with the horizontal delta from the
    /// drag-start position. The window controller adds it to its
    /// snapshot, clamps, and applies.
    var onDragChanged: ((CGFloat) -> Void)?

    /// Called on mouseUp so the controller can persist the final width.
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .cursorUpdate keeps the resize cursor sticky even when AppKit
        // would otherwise reset to the arrow mid-drag.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragChanged?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
