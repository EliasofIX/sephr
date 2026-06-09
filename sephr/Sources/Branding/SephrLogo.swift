import SwiftUI

/// The Sephr wordmark / asterism-in-brackets. Renders purely as text at
/// call-sites; a scalable vector version lives in Assets.xcassets if
/// bitmap export is needed.
struct SephrLogo: View {
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var color: Color = .primary.opacity(0.7)

    var body: some View {
        Text("[✺]")
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
    }
}
