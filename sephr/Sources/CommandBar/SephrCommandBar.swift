import SwiftUI
import AppKit

@MainActor
enum SephrCommandBar {
    private static var panel: NSPanel?

    static func show(in wc: SephrWindowController? = nil) {
        dismiss()
        // `.nonactivatingPanel` was here to keep the host app from
        // backgrounding when the palette is shown. With Chromium in charge
        // of NSApp.delegate, NSApp activation state isn't ours to manage
        // — and crucially, a non-activating panel cannot accept first
        // responder for SwiftUI TextField input, which is the entire
        // point of the command bar. Drop it; the panel now activates
        // properly and the TextField can take keystrokes.
        //
        // Subclassing NSPanel so we can override `canBecomeKey` /
        // `canBecomeMain` (borderless panels say "no" by default — the
        // text field then can't receive input even though the panel is
        // visible).
        final class KeyablePanel: NSPanel {
            override var canBecomeKey: Bool { true }
            override var canBecomeMain: Bool { true }
        }
        // A pure `.borderless` panel — no `.titled`. The previous style mask
        // included `.titled`, which makes AppKit draw a window theme frame +
        // (transparent) titlebar *behind* our clear panel; that chrome was
        // the stray rounded "bow"/notch poking out above the pill. Borderless
        // draws nothing of its own, so only the SwiftUI pill is visible.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The pill carries its own SwiftUI drop shadow; a window-level shadow
        // over the large transparent canvas would fight it.
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let vm = SephrCommandBarViewModel(windowController: wc)
        let view = SephrCommandBarView(viewModel: vm) { dismiss() }
        panel.contentView = NSHostingView(rootView: view)

        // Spotlight-style placement: horizontally centred, anchored in the
        // upper third of the screen the browser window lives on. The screen is
        // resolved deterministically and the final origin is clamped inside the
        // visible frame, so the palette can never drift off-centre or float
        // above the top edge of the screen ("above the window").
        let vf = Self.targetScreen(for: wc).visibleFrame
        let size = panel.frame.size
        // Horizontally centred within the visible frame.
        var x = vf.minX + (vf.width - size.width) / 2
        // The pill is top-anchored inside the panel, so anchoring the panel's
        // TOP edge ~12% down from the top lands the pill in the upper third.
        var y = vf.maxY - size.height - vf.height * 0.12
        // Clamp so the panel always stays within the visible frame: its top can
        // never rise above the screen and its body never runs off a side. When
        // the panel is taller than the screen the upper bound wins, keeping the
        // pill pinned at the top rather than pushed off it.
        x = min(max(x, vf.minX), max(vf.minX, vf.maxX - size.width))
        y = min(max(y, vf.minY), vf.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Activate the app + force ourselves to key so the TextField can
        // take input even when Chromium's hidden Browser is otherwise
        // installed as a key candidate.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        Self.panel = panel
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Resolve the screen the palette should appear on, deterministically.
    /// `NSWindow.screen` returns nil while a window is offscreen/mid-move and
    /// `NSScreen.main` follows keyboard focus (which the palette is about to
    /// steal), so prefer the screen physically containing the host window's
    /// centre. Falls back to the window's own screen, then the menu-bar screen.
    private static func targetScreen(for wc: SephrWindowController?) -> NSScreen {
        if let win = wc?.window {
            let centre = NSPoint(x: win.frame.midX, y: win.frame.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
                return s
            }
            if let s = win.screen { return s }
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}

struct SephrCommandBarView: View {
    @ObservedObject var viewModel: SephrCommandBarViewModel
    let onDismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Results render only once the user has typed something — an empty
    /// query leaves just the bare search pill (Spotlight behaviour).
    private var showResults: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.results.isEmpty
    }

    /// Pill corner radius — matched by the focus-ring overlay so the
    /// glow stays seated on the glass edge.
    private static let pillCorner: CGFloat = 18

    var body: some View {
        ZStack(alignment: .top) {
            // Click anywhere outside the pill to dismiss, like Spotlight.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack(spacing: DC.Space.m) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(focused ? DC.Ink.ink2 : DC.Ink.ink3)
                    TextField("Search or enter URL…", text: $query)
                        .textFieldStyle(.plain)
                        .font(DC.TypeScale.headline)
                        .foregroundStyle(DC.Ink.ink)
                        .focused($focused)
                        .onChange(of: query) { _, new in viewModel.search(new) }
                        .onSubmit { viewModel.activateFirst(); onDismiss() }
                }
                .padding(.horizontal, DC.Space.l)
                .padding(.vertical, DC.Space.m + 3)

                if showResults {
                    Divider().opacity(0.6)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // enumerated() so each row knows its position
                            // in the visible list and can stagger its own
                            // fade-in — capped at six steps so the tail
                            // of a long list doesn't drift in late.
                            ForEach(
                                Array(viewModel.results.enumerated()),
                                id: \.element.id
                            ) { idx, result in
                                CommandResultRow(result: result,
                                                 index: idx) {
                                    viewModel.activate(result)
                                    onDismiss()
                                }
                            }
                        }
                        .padding(DC.Space.s)
                    }
                    .frame(maxHeight: 360)
                }
            }
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(LiquidGlassPanel(cornerRadius: Self.pillCorner))
            // Focus ring — a 1pt hairline stroke that fades in only when
            // the field has keyboard focus. Animates with the same hover
            // curve so it crossfades softly instead of snapping in.
            .overlay(
                RoundedRectangle(cornerRadius: Self.pillCorner,
                                 style: .continuous)
                    .strokeBorder(DC.Ink.ink2.opacity(0.35),
                                  lineWidth: 1)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : DC.Motion.hover,
                               value: focused))
            .padding(.top, DC.Space.xl)
            .animation(reduceMotion ? nil : DC.Motion.easeOutFast,
                       value: showResults)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onExitCommand { onDismiss() }
    }
}

/// Real macOS 26 Liquid Glass surface for the command palette / floating pill.
///
/// Apply `.glassEffect(in:)` DIRECTLY on the content — do NOT wrap it in a
/// `.background { Color.clear.glassEffect() }.clipShape(...)`: the outer
/// `clipShape` chops Liquid Glass's soft ambient shadow into a hard "box",
/// and stacking a manual `.shadow(...)` on top compounds it. Applied directly,
/// glass renders with Apple's clean, subtle floating edge and no artifact.
/// Falls back to `.ultraThinMaterial` only on pre-26 systems that lack glass.
struct LiquidGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                     style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

struct CommandResultRow: View {
    let result: SephrSearchResult
    var index: Int = 0
    let action: () -> Void

    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stagger the first six rows in by 22 ms each so the list appears
    /// as a soft cascade rather than a slab. Past six, every row uses
    /// the cap so a long list tail doesn't drift in late.
    private var staggerDelay: Double {
        reduceMotion ? 0 : Double(min(index, 6)) * 0.022
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DC.Space.m) {
                if let fav = result.favicon {
                    Image(nsImage: fav).resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: result.systemIcon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? DC.Ink.ink : DC.Ink.ink2)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DC.Ink.ink)
                        .lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(DC.Ink.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(result.typeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(hovering ? DC.Ink.ink2 : DC.Ink.ink4)
            }
            .padding(.horizontal, DC.Space.m)
            .padding(.vertical, DC.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering
                      ? DC.Ink.hairline
                      : DC.Ink.surface.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Slight lift on hover so the active row separates from siblings
        // without changing the row's hit-target box.
        .scaleEffect(hovering ? 1.008 : 1)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 4)
        .animation(reduceMotion ? nil : DC.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .onAppear {
            // Stagger only the entrance; subsequent recomputes (typing,
            // reordering) skip the delay because `appeared` stays true
            // once the row first lands.
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
                return
            }
            withAnimation(DC.Motion.easeOutFast.delay(staggerDelay)) {
                appeared = true
            }
        }
    }
}
