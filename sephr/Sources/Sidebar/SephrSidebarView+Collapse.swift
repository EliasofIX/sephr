import AppKit

extension SephrSidebarView {

    /// Called when the user drags the sidebar past the zero threshold.
    /// The spring curve in `setWidth` is what gives the snap-into-edge
    /// feel now — the previous fade-to-zero-then-snap trick was a
    /// workaround for `easeInEaseOut` looking sluggish from a near-zero
    /// starting width. With a snappy spring, a near-zero starting width
    /// already lands in ~50ms perceptually, so the fade is unnecessary.
    func animateCollapseWithBounceBack() {
        collapse(animated: true)
    }
}
