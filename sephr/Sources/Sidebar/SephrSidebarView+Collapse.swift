import AppKit

extension SephrSidebarView {

    /// Smooth two-stage animation used when a user drags the sidebar past
    /// the zero threshold: slide to 0 → detach → hide. Matches Arc's
    /// feel of the sidebar "snapping away" into the window edge.
    func animateCollapseWithBounceBack() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            self.collapse(animated: false)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.0
                self.animator().alphaValue = 1
            }
        })
    }
}
