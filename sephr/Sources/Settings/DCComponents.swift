import SwiftUI
import AppKit

// MARK: — TextField write debounce

/// Coalesce free-text field writes (Profile name, Custom Search URL) so a
/// burst of keystrokes lands as a single `UserDefaults.set` instead of one
/// per character. UserDefaults posts NSUserDefaultsDidChangeNotification +
/// KVO globally on each `set`; the debounce squashes the storm into one
/// trailing write 250 ms after the typist pauses. Always flush from the
/// pane's `onDisappear` so the last edit isn't lost on a tab swap.
@MainActor
final class TextDebouncer: ObservableObject {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(delay: TimeInterval = 0.25) { self.delay = delay }
    deinit { work?.cancel() }
    /// Schedule `apply` to run after `delay`, cancelling any pending one.
    func schedule(_ apply: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: apply)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    /// Run any pending write immediately. Safe to call when nothing is
    /// pending — it just no-ops.
    func flush() {
        guard let w = work else { return }
        w.cancel()
        work = nil
        w.perform()
    }
}

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
        // Equality-guard each property — SwiftUI calls updateNSView on
        // every parent body recompute and the values are constants in
        // every existing call site. Assigning identical values still
        // triggers the NSVisualEffectView's internal KVO chain and a
        // layer reconfigure pass; the guards make this a no-op when the
        // representable is mounted with stable values.
        if v.material != material { v.material = material }
        if v.blendingMode != blending { v.blendingMode = blending }
        if v.state != .active { v.state = .active }
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
        TabBarButton(item: item,
                     isSelected: isSelected,
                     namespace: pill,
                     reduceMotion: reduceMotion) {
            withAnimation(reduceMotion ? nil : DC.Motion.spring) {
                selection = item.tab
            }
        }
    }
}

/// One pill button in `DCTabBar`. Lifted out of the parent so the per-
/// button hover state lives in its own struct (Button-style-styled views
/// inside a ForEach share their `@State` if declared on the outer view).
/// Unselected tabs gain a subtle hover ink-brightening; the selected tab
/// is already filled and skips the hover treatment so the matched-geometry
/// pill doesn't fight a duplicate background.
private struct TabBarButton<Tab: Hashable>: View {
    let item: DCTabItem<Tab>
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(item.title)
                    .font(DC.TypeScale.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DC.Ink.field
                             : (hovering ? DC.Ink.ink : DC.Ink.ink2))
            .frame(minWidth: 60, minHeight: 44)
            .padding(.vertical, DC.Space.s)
            .padding(.horizontal, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DC.Ink.ink)
                        .matchedGeometryEffect(id: "selection",
                                               in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DC.Ink.surface)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton]
                                            : .isButton)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DC.Motion.hover, value: hovering)
    }
}
