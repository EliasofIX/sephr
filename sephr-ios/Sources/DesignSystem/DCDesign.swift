import SwiftUI
import UIKit

/// A monochrome token that resolves to its light- or dark-mode value from
/// the trait collection, so SwiftUI re-resolves it automatically when the
/// interface style flips.
func dcDynamic(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    })
}

/// DIGITAL CAVIAR — design tokens shared by Sephr's native chrome.
/// Monochrome only: depth comes from value, material, and typography.
/// iOS port of the macOS tokens in sephr/Sources/Settings/DCDesign.swift —
/// keep the ramps in sync when either changes.
enum DC {

    // MARK: — Value (monochrome only)
    //
    // The value ramp is *relative*, not fixed to dark: every token resolves
    // to a light- or dark-mode variant from the trait collection. Because
    // all of Sephr's native chrome is built on these tokens, inverting them
    // here flips the whole surface coherently.
    enum Ink {
        static let field = dcDynamic(
            light: UIColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1),
            dark:  UIColor(red: 0.039, green: 0.047, blue: 0.059, alpha: 1))
        static let ink = dcDynamic(
            light: UIColor(red: 0.071, green: 0.086, blue: 0.106, alpha: 1),
            dark:  UIColor(red: 0.957, green: 0.965, blue: 0.973, alpha: 1))
        static let ink2 = dcDynamic(light: UIColor(white: 0.30, alpha: 1),
                                    dark:  UIColor(white: 0.62, alpha: 1))
        static let ink3 = dcDynamic(light: UIColor(white: 0.44, alpha: 1),
                                    dark:  UIColor(white: 0.38, alpha: 1))
        static let ink4 = dcDynamic(light: UIColor(white: 0.58, alpha: 1),
                                    dark:  UIColor(white: 0.24, alpha: 1))
        static let hairline = dcDynamic(light: UIColor(white: 0, alpha: 0.12),
                                        dark:  UIColor(white: 1, alpha: 0.10))
        static let surface  = dcDynamic(light: UIColor(white: 0, alpha: 0.05),
                                        dark:  UIColor(white: 1, alpha: 0.06))
    }

    // MARK: — Shape
    enum Radius {
        /// Standard corner radius for bars, panels, rows, and controls.
        static let standard: CGFloat = 8
    }

    // MARK: — Spacing (4pt base)
    enum Space {
        static let xs:     CGFloat = 4
        static let s:      CGFloat = 8
        static let m:      CGFloat = 12
        static let l:      CGFloat = 16
        static let xl:     CGFloat = 24
        static let xxl:    CGFloat = 32
        static let huge:   CGFloat = 48
        static let margin: CGFloat = 20
    }

    // MARK: — Type
    enum TypeScale {
        static let display  = Font.system(size: 40, weight: .bold)
        static let title    = Font.system(size: 24, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body     = Font.system(size: 17, weight: .regular)
        static let callout  = Font.system(size: 15, weight: .regular)
        static let caption  = Font.system(size: 12, weight: .regular)
        static let label    = Font.system(size: 11, weight: .semibold)
        static let data     = Font.system(size: 13, weight: .medium,
                                          design: .monospaced)
    }
}

extension View {
    /// Hairline width for the current display.
    var dcHairline: CGFloat { 1.0 / UITraitCollection.current.displayScale }
}

// MARK: — Signature modifiers

extension View {
    /// Wide-tracked, uppercase, tertiary-ink eyebrow label. Restraint —
    /// one or two per screen, used as section openers.
    func dcLabel() -> some View {
        self.font(DC.TypeScale.label)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(DC.Ink.ink3)
    }

    /// Monochrome glass surface — real Liquid Glass on iOS 26, with a
    /// hairline border carrying the specular cue without any hue.
    func dcGlass(cornerRadius: CGFloat = DC.Radius.standard) -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(
                cornerRadius: cornerRadius, style: .continuous))
    }

    /// Static glass for surfaces inside scrolling content where the full
    /// dynamic glass would be overkill — material + hairline.
    func dcSurface(cornerRadius: CGFloat = DC.Radius.standard) -> some View {
        self.background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius,
                                             style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius,
                                      style: .continuous)
                .strokeBorder(DC.Ink.hairline, lineWidth: 1))
    }
}

// MARK: — Monochrome controls

/// Primary action — a near-white solid pill on the dark field. One per
/// screen. Everything else uses the secondary glass variant.
struct DCPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DC.TypeScale.headline)
            .foregroundStyle(DC.Ink.field)
            .padding(.horizontal, DC.Space.xl)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .fill(DC.Ink.ink)
                    .opacity(configuration.isPressed ? 0.82 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.9),
                       value: configuration.isPressed)
    }
}

struct DCSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DC.TypeScale.callout)
            .foregroundStyle(DC.Ink.ink)
            .padding(.horizontal, DC.Space.l)
            .padding(.vertical, DC.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .fill(DC.Ink.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DC.Radius.standard,
                                          style: .continuous)
                            .strokeBorder(DC.Ink.hairline, lineWidth: 1))
                    .opacity(configuration.isPressed ? 0.72 : 1))
    }
}

// MARK: — AI affordance shimmer
//
// DC monochrome replacement for Arc's pink/purple gradient sweep that
// marks AI surfaces. We breathe the foreground opacity between full and
// 55% — the eye reads it as "thinking" without any chroma. Applied to
// the "Reading N pages" headline, the SuperBrowse pill while active, and
// the Writing… eyebrow during streaming.
private struct DCLuminanceShimmer: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.55 : 1.0)
            .onAppear { startIfNeeded() }
            .onChange(of: active) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        guard active else {
            withAnimation(.easeOut(duration: 0.18)) { dim = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.0)
            .repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

extension View {
    /// Monochrome luminance pulse for AI affordances. No-op when `active`
    /// is false — safe to attach permanently and flip per state.
    func dcLuminanceShimmer(active: Bool = true) -> some View {
        modifier(DCLuminanceShimmer(active: active))
    }
}

// MARK: — SuperBrowse pill
//
// Inline action chip surfaced beside each suggestion row in the search
// overlay and above the typed-query row. Triggers SuperBrowse on the
// adjacent query. Designed to read as a peer to the row, not a system
// button — narrow capsule, hairline border, body weight.
struct SuperBrowsePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("SuperBrowse")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DC.Ink.ink)
                .padding(.horizontal, DC.Space.m)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DC.Radius.standard,
                                     style: .continuous)
                        .fill(DC.Ink.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DC.Radius.standard,
                                              style: .continuous)
                                .strokeBorder(DC.Ink.hairline, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("SuperBrowse this query")
    }
}
