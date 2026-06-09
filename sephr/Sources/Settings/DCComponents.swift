import SwiftUI
import AppKit

/// Structural components for the settings surface, built on the DIGITAL
/// CAVIAR tokens in `DCDesign.swift`. These are the pieces the Arc-shaped
/// layout needs that the base row/section primitives don't cover: the
/// behind-window glass backing, the top tab bar, and the generated
/// gradient avatar.

// MARK: — Liquid Glass backing

/// Behind-window blur — the genuine macOS "liquid glass" surface. Renders
/// the desktop/wallpaper *through* the settings window so the chrome
/// floats on a live translucent field rather than a flat fill. This is
/// the min-target (macOS 14) path to real glass; on macOS 26 the same
/// NSVisualEffectView resolves to the system Liquid Glass material. The
/// window itself must be non-opaque with a clear background for the blur
/// to reach the desktop — see `SephrSettingsController`.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

// MARK: — Tab bar

/// One entry in the settings tab bar: a section, its label, and its
/// SF Symbol.
struct DCTabItem<Tab: Hashable>: Identifiable {
    let tab: Tab
    let title: String
    let systemImage: String
    var id: Tab { tab }
}

/// Arc-style centered tab bar: a row of icon-over-label buttons in a
/// floating capsule, with the selected tab filled and the pill sliding
/// between tabs. The capsule is **real Liquid Glass** via the macOS 26
/// `glassEffect` API (the floating functional layer Apple's HIG describes
/// for navigation) — `ultraThinMaterial` only as a pre-26 fallback. Motion
/// respects Reduce Motion; every button clears the 44pt hit target.
struct DCTabBar<Tab: Hashable>: View {
    let items: [DCTabItem<Tab>]
    @Binding var selection: Tab

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var row: some View {
        HStack(spacing: DC.Space.xs) {
            ForEach(items) { item in button(for: item) }
        }
        .padding(DC.Space.xs)
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            row.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            row.dcGlass(cornerRadius: 22)
        }
    }

    @ViewBuilder
    private func button(for item: DCTabItem<Tab>) -> some View {
        let isSelected = item.tab == selection
        Button {
            withAnimation(reduceMotion ? nil
                          : .spring(response: 0.32, dampingFraction: 0.86)) {
                selection = item.tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(item.title)
                    .font(DC.TypeScale.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DC.Ink.field : DC.Ink.ink2)
            .frame(minWidth: 60, minHeight: 44)
            .padding(.vertical, DC.Space.s)
            .padding(.horizontal, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DC.Ink.ink)
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton]
                                            : .isButton)
    }
}

// MARK: — Generated gradient avatar

/// Generated gradient "portrait" — Sephr's analogue of Arc's profile
/// blobs. Deterministic from a seed so a given profile always renders the
/// same swatch. The single sanctioned splash of colour in the otherwise
/// monochrome settings surface; everything else stays on the value ramp.
struct DCGradientAvatar: View {
    let seed: Int

    var body: some View {
        LinearGradient(colors: Self.palette(for: seed),
                       startPoint: .top,
                       endPoint: .bottomTrailing)
            .overlay(
                // A soft highlight so the swatch reads as a rounded form,
                // not a flat fill — the Apple specular cue, in colour.
                RadialGradient(
                    colors: [Color.white.opacity(0.22), .clear],
                    center: .init(x: 0.32, y: 0.22),
                    startRadius: 2, endRadius: 160)
            )
    }

    /// Muted, Arc-adjacent gradients. Indexed cyclically by seed.
    static func palette(for seed: Int) -> [Color] {
        let sets: [[Color]] = [
            [Color(red: 0.42, green: 0.46, blue: 0.78),
             Color(red: 0.60, green: 0.46, blue: 0.72),
             Color(red: 0.28, green: 0.36, blue: 0.55)],
            [Color(red: 0.26, green: 0.54, blue: 0.60),
             Color(red: 0.44, green: 0.63, blue: 0.56)],
            [Color(red: 0.78, green: 0.52, blue: 0.46),
             Color(red: 0.66, green: 0.42, blue: 0.50)],
            [Color(red: 0.50, green: 0.52, blue: 0.58),
             Color(red: 0.32, green: 0.34, blue: 0.40)],
            [Color(red: 0.78, green: 0.66, blue: 0.40),
             Color(red: 0.60, green: 0.50, blue: 0.42)],
            [Color(red: 0.40, green: 0.60, blue: 0.74),
             Color(red: 0.30, green: 0.44, blue: 0.62)],
        ]
        let n = sets.count
        return sets[((seed % n) + n) % n]
    }
}
