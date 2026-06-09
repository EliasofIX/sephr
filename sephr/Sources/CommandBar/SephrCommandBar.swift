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
        // upper third of the active screen rather than dead-centre.
        if let screen = wc?.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            let x = vf.midX - size.width / 2
            let y = vf.maxY - size.height - vf.height * 0.10
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
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
}

struct SephrCommandBarView: View {
    @ObservedObject var viewModel: SephrCommandBarViewModel
    let onDismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    /// Results render only once the user has typed something — an empty
    /// query leaves just the bare search pill (Spotlight behaviour).
    private var showResults: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.results.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Click anywhere outside the pill to dismiss, like Spotlight.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    TextField("Search or enter URL...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onChange(of: query) { _, new in viewModel.search(new) }
                        .onSubmit { viewModel.activateFirst(); onDismiss() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                if showResults {
                    Divider().opacity(0.6)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(viewModel.results) { result in
                                CommandResultRow(result: result) {
                                    viewModel.activate(result)
                                    onDismiss()
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                }
            }
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(LiquidGlassPanel())
            .padding(.top, 24)
            .animation(.easeOut(duration: 0.12), value: showResults)
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
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let fav = result.favicon {
                    Image(nsImage: fav).resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: result.systemIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 13, weight: .medium))
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(result.typeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
