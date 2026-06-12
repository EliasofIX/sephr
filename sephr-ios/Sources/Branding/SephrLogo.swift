import SwiftUI

/// The Sephr wordmark / asterism-in-brackets. Same mark as the macOS app
/// (sephr/Sources/Branding/SephrLogo.swift) — renders purely as text.
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
