import SwiftUI

/// The Sephr wordmark / asterism-in-brackets. Renders purely as text at
/// call-sites; a scalable vector version lives in Assets.xcassets if
/// bitmap export is needed.
///
/// Pass `breathing: true` on quiet/empty/loading surfaces (welcome
/// screens, blank tab placeholders) for a slow opacity breath that hints
/// at life without animating anything load-bearing. Default off so the
/// mark stays static everywhere it's used as decoration in a denser UI.
/// Reduce Motion suppresses the breath and pins the opacity at the
/// midpoint instead.
struct SephrLogo: View {
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var color: Color = .primary.opacity(0.7)
    var breathing: Bool = false

    @State private var breathOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opacity envelope for the breath: a calm 4.4s cycle, riding between
    /// 60% and 100% so the mark never disappears at the trough.
    private static let breathLow: Double = 0.60
    private static let breathHigh: Double = 1.0
    private static let breathPeriod: Double = 4.4

    var body: some View {
        Text("[✺]")
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .opacity(currentOpacity)
            .animation(reduceMotion || !breathing
                       ? nil
                       : .easeInOut(duration: Self.breathPeriod)
                            .repeatForever(autoreverses: true),
                       value: breathOut)
            .onAppear {
                guard breathing, !reduceMotion else { return }
                breathOut = true
            }
            .accessibilityHidden(true)
    }

    private var currentOpacity: Double {
        guard breathing else { return 1 }
        if reduceMotion {
            return (Self.breathLow + Self.breathHigh) / 2
        }
        return breathOut ? Self.breathLow : Self.breathHigh
    }
}
