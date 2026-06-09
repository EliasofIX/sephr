import AppKit

/// A small Liquid Glass button parked in the top-left of a split pane.
/// Clicking it breaks the split and makes that pane's tab the full tab.
/// Built as a bare NSView (not NSButton) so the NSGlassEffectView reads
/// as the button surface rather than fighting NSButton's own chrome.
final class SephrSplitExpandButton: NSView {

    private let onClick: () -> Void
    private let icon = NSImageView()

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        // Liquid Glass backdrop — same posture as the sidebar tab pills
        // (NSGlassEffectView on macOS 26, NSVisualEffectView fallback).
        let glass: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 14
            g.tintColor = nil
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 14
            v.layer?.masksToBounds = true
            glass = v
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        // A touch more see-through so the page shows through the glass —
        // only the backdrop is dimmed; the icon below stays fully opaque.
        glass.alphaValue = 0.6
        addSubview(glass)

        icon.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Expand to full tab")
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Swallow mouseDown so the press doesn't fall through to the web view
    // beneath; fire on mouseUp only if released inside the bounds.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
