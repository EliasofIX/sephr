import AppKit

/// Drives the cross-fade used when flipping between compact and full sidebar
/// widths. Kept as a helper so the sidebar view doesn't own the
/// NSAnimationContext gymnastics directly.
@MainActor
final class SephrCompactModeController {

    static func transition(sidebar: SephrSidebarView, toCompact: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebar.animator().alphaValue = 0.6
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sidebar.animator().alphaValue = 1.0
            }
        }
    }
}
