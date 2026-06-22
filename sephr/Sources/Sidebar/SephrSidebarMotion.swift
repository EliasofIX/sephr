import AppKit
import QuartzCore

/// Motion tokens for the docked + floating sidebar transitions. Keeping the
/// curve and duration in one place stops the two callers (the sidebar's own
/// width constraint and the window's mirror constraint) from drifting apart
/// — they have to animate in perfect lockstep or the sidebar visibly tears
/// from its slot mid-transition.
@MainActor
enum SephrSidebarMotion {

    /// Approximation of an Apple interpolating spring as a cubic Bezier,
    /// suitable for `NSAnimationContext.timingFunction`. We can't hand
    /// NSLayoutConstraint a real `CASpringAnimation`, so this is the closest
    /// "smooth, crisp departure, gentle landing" curve we can express in
    /// the NSAnimationContext world. Maps roughly to the Tahoe sidebar's
    /// own collapse curve.
    static let snappyCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let snappyDuration: CFTimeInterval = 0.34

    /// Real spring for layer-driven animations (the floating overlay's
    /// transform + opacity). `perceptualDuration` is how long the motion
    /// *reads* as taking; `bounce` controls overshoot — keep it tiny so it
    /// nudges into place instead of wobbling.
    static func spring(
        keyPath: String,
        bounce: CGFloat = 0.12,
        perceptualDuration: CFTimeInterval = 0.36
    ) -> CASpringAnimation {
        let s = CASpringAnimation(perceptualDuration: perceptualDuration, bounce: bounce)
        s.keyPath = keyPath
        s.isRemovedOnCompletion = true
        s.fillMode = .both
        return s
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
