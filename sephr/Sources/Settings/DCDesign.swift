import SwiftUI
import AppKit

/// A monochrome token that resolves to its light- or dark-mode value from
/// the drawing context's effective appearance, so SwiftUI re-resolves it
/// automatically when the window flips between Light and Dark.
func dcDynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? dark : light
    })
}

/// DIGITAL CAVIAR — design tokens shared by Sephr's native chrome.
/// Monochrome only: depth comes from value, material, and typography.
/// macOS port of the iOS tokens; replace UIScreen with NSScreen and
/// platform colour APIs accordingly.
enum DC {

    // MARK: — Value (monochrome only)
    //
    // The value ramp is *relative*, not fixed to dark: every token resolves
    // to a light- or dark-mode variant from the window's effective
    // appearance. Because all of Sephr's native chrome is built on these
    // tokens, inverting them here flips the whole surface coherently — dark
    // ink on a light glass in Light mode, light ink on a near-black field in
    // Dark mode. The relationships (e.g. toggle thumb = `field`, track =
    // `ink`) stay correct in both because both ends invert together.
    enum Ink {
        static let field = dcDynamic(
            light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1),
            dark:  NSColor(srgbRed: 0.039, green: 0.047, blue: 0.059, alpha: 1))
        static let ink = dcDynamic(
            light: NSColor(srgbRed: 0.071, green: 0.086, blue: 0.106, alpha: 1),
            dark:  NSColor(srgbRed: 0.957, green: 0.965, blue: 0.973, alpha: 1))
        static let ink2 = dcDynamic(light: NSColor(white: 0.30, alpha: 1),
                                    dark:  NSColor(white: 0.62, alpha: 1))
        static let ink3 = dcDynamic(light: NSColor(white: 0.44, alpha: 1),
                                    dark:  NSColor(white: 0.38, alpha: 1))
        static let ink4 = dcDynamic(light: NSColor(white: 0.58, alpha: 1),
                                    dark:  NSColor(white: 0.24, alpha: 1))
        static let hairline = dcDynamic(light: NSColor(white: 0, alpha: 0.12),
                                        dark:  NSColor(white: 1, alpha: 0.10))
        static let surface  = dcDynamic(light: NSColor(white: 0, alpha: 0.05),
                                        dark:  NSColor(white: 1, alpha: 0.06))
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
        static let margin: CGFloat = 24
    }

    // MARK: — Type
    enum TypeScale {
        static let display  = Font.system(size: 40, weight: .bold)
        static let title    = Font.system(size: 22, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body     = Font.system(size: 15, weight: .regular)
        static let caption  = Font.system(size: 12, weight: .regular)
        static let label    = Font.system(size: 11, weight: .semibold)
        static let data     = Font.system(size: 12, weight: .medium,
                                          design: .monospaced)
    }

    // MARK: — Motion
    //
    // One source of truth for every micro-animation in the native chrome.
    // Pre-tokens the surface mixed `.spring(response: 0.25, 0.9)` (primary
    // button), `.spring(0.32, 0.86)` (tab bar), `.spring(0.35, 0.9)`
    // (toggle), `.easeOut(0.12)` (command bar), `.easeInOut(0.16)` (pane
    // crossfade), `.easeOut(0.15)` (peek hover). The values were all
    // plausible in isolation but read incoherent next to each other.
    //
    //   • spring        — selection / state change. Premium settled feel,
    //                     matches the tab-bar pill's existing motion.
    //   • springSnappy  — button press + release. Sub-perception fast.
    //   • easeOutFast   — quick reveals (command bar, hover swaps).
    //   • easeOutPane   — pane crossfades (settings, layered overlays).
    //   • hover         — hover-state opacity/scale transitions on chrome.
    enum Motion {
        static let spring       = Animation.spring(response: 0.32,
                                                   dampingFraction: 0.86)
        static let springSnappy = Animation.spring(response: 0.22,
                                                   dampingFraction: 0.9)
        static let easeOutFast  = Animation.easeOut(duration: 0.12)
        static let easeOutPane  = Animation.easeInOut(duration: 0.16)
        static let hover        = Animation.easeOut(duration: 0.14)
    }

    static var hairlineWidth: CGFloat {
        1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    }
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

    /// Monochrome glass surface — ultra-thin material clipped to a
    /// continuous corner with a hairline border. The Apple specular cue
    /// without any hue.
    func dcGlass(cornerRadius: CGFloat = DC.Radius.standard) -> some View {
        self.background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius,
                                 style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius,
                                  style: .continuous)
                    .strokeBorder(DC.Ink.hairline,
                                  lineWidth: DC.hairlineWidth))
    }
}

// MARK: — Monochrome controls

/// Toggle without hue. Track flips between surface and ink; thumb is
/// the inverse. Calm spring on flip. No "accent colour" anywhere.
struct DCToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DC.Space.l) {
            configuration.label
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink)
            Spacer(minLength: DC.Space.s)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .fill(configuration.isOn
                          ? AnyShapeStyle(DC.Ink.ink)
                          : AnyShapeStyle(DC.Ink.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: DC.Radius.standard,
                                          style: .continuous)
                            .strokeBorder(DC.Ink.hairline,
                                          lineWidth: DC.hairlineWidth))
                    .frame(width: 44, height: 26)

                Circle()
                    .fill(configuration.isOn
                          ? DC.Ink.field
                          : DC.Ink.ink2)
                    .frame(width: 22, height: 22)
                    .padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(DC.Motion.spring) {
                    configuration.isOn.toggle()
                }
            }
        }
    }
}

/// Quiet text input. Sits on a glass surface with a hairline border,
/// monospaced field text for "value" feel.
struct DCTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .font(DC.TypeScale.data)
            .foregroundStyle(DC.Ink.ink)
            .textFieldStyle(.plain)
            .padding(.horizontal, DC.Space.m)
            .padding(.vertical, DC.Space.s)
            .frame(minHeight: 32)
            .background(DC.Ink.surface,
                        in: RoundedRectangle(cornerRadius: DC.Radius.standard,
                                              style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .strokeBorder(DC.Ink.hairline,
                                  lineWidth: DC.hairlineWidth))
    }
}

/// Primary action — a near-white solid pill on the dark field. One per
/// screen. Everything else uses the secondary glass variant.
struct DCPrimaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DC.TypeScale.headline)
            .foregroundStyle(DC.Ink.field)
            .padding(.horizontal, DC.Space.xl)
            .padding(.vertical, DC.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .fill(DC.Ink.ink)
                    // Hover lifts the bar subtly; press settles it. The
                    // two opacities never collide because isPressed wins.
                    .opacity(configuration.isPressed ? 0.82
                             : (hovering ? 0.94 : 1)))
            .scaleEffect(configuration.isPressed ? 0.98
                         : (hovering ? 1.015 : 1))
            .animation(DC.Motion.springSnappy,
                       value: configuration.isPressed)
            .animation(DC.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct DCSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DC.TypeScale.body)
            .foregroundStyle(DC.Ink.ink)
            .padding(.horizontal, DC.Space.l)
            .padding(.vertical, DC.Space.s)
            .background(
                RoundedRectangle(cornerRadius: DC.Radius.standard,
                                 style: .continuous)
                    .fill(hovering ? DC.Ink.hairline : DC.Ink.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DC.Radius.standard,
                                          style: .continuous)
                            .strokeBorder(DC.Ink.hairline,
                                          lineWidth: DC.hairlineWidth))
                    .opacity(configuration.isPressed ? 0.72 : 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            // Pre-tokens this had NO animation: the opacity flipped
            // instantly between press states and the hover state didn't
            // exist at all. Now both ride the unified spring/hover curve.
            .animation(DC.Motion.springSnappy,
                       value: configuration.isPressed)
            .animation(DC.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: — Row primitives

/// Generic settings row: title on the left, value on the right.
/// Always sits inside a glass surface; arrange in a VStack with
/// DC.Space.m between rows.
struct DCRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: DC.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(DC.TypeScale.caption)
                        .foregroundStyle(DC.Ink.ink3)
                }
            }
            Spacer(minLength: DC.Space.s)
            trailing()
        }
        .padding(DC.Space.l)
        .dcGlass()
    }
}

/// Section frame: wide-tracked uppercase eyebrow, generous gap, then
/// the section's content stack. Use throughout settings.
struct DCSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DC.Space.l) {
            Text(title).dcLabel()
            VStack(spacing: DC.Space.m) {
                content()
            }
        }
    }
}
