import AppKit

protocol SephrSplitDropViewDelegate: AnyObject {
    /// Whether dropping the tab with this id would produce a valid split
    /// right now — there must be an active tab to pair with, the dragged
    /// tab must be a different one, and we mustn't already be split.
    func splitDropView(_ view: SephrSplitDropView, canSplitWith tabID: UUID) -> Bool
    /// The user released a tab drag inside the split zone — enter split
    /// view with this tab as the secondary pane.
    func splitDropView(_ view: SephrSplitDropView, didRequestSplitWith tabID: UUID)
}

/// The web-content host doubles as a drop target: dragging a sidebar tab
/// into the trailing half of the page enters split view (current tab on
/// the left, dropped tab on the right). A translucent accent panel
/// previews the landing zone while the drag hovers there.
final class SephrSplitDropView: NSView {

    weak var dropDelegate: SephrSplitDropViewDelegate?

    /// Fraction of the width, measured from the trailing edge, that counts
    /// as the "drop here to split" zone. Mirrors the Arc/Safari gesture —
    /// you fling a tab toward the right edge to pop a second pane.
    private static let zoneFraction: CGFloat = 0.5

    private var highlight: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([SephrTabPasteboard.type])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Zone math

    private var zoneRect: NSRect {
        let w = bounds.width * Self.zoneFraction
        return NSRect(x: bounds.maxX - w, y: 0, width: w, height: bounds.height)
    }

    private func inZone(_ sender: any NSDraggingInfo) -> Bool {
        zoneRect.contains(convert(sender.draggingLocation, from: nil))
    }

    /// Resolves the drag to a draggable, split-eligible tab id sitting in
    /// the trailing zone, or nil if the drop should be refused.
    private func eligibleTabID(_ sender: any NSDraggingInfo) -> UUID? {
        guard let id = SephrTabPasteboard.tabID(from: sender.draggingPasteboard),
              dropDelegate?.splitDropView(self, canSplitWith: id) == true,
              inZone(sender)
        else { return nil }
        return id
    }

    // MARK: — NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        removeHighlight()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        removeHighlight()
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard eligibleTabID(sender) != nil else {
            removeHighlight()
            return []
        }
        showHighlight()
        // .copy reads as "also open here" (the green +), not "move out of
        // the sidebar". SephrTabCell's source mask offers both.
        return .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        eligibleTabID(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { removeHighlight() }
        guard let id = eligibleTabID(sender) else { return false }
        dropDelegate?.splitDropView(self, didRequestSplitWith: id)
        return true
    }

    // MARK: — Landing-zone preview

    private func showHighlight() {
        if let highlight {
            highlight.frame = zoneRect
            return
        }
        let v = NSView(frame: zoneRect)
        v.wantsLayer = true
        v.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        v.layer?.borderColor =
            NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 8
        // Top-most so it reads over the opaque web page beneath it.
        addSubview(v)
        highlight = v
    }

    private func removeHighlight() {
        highlight?.removeFromSuperview()
        highlight = nil
    }
}
