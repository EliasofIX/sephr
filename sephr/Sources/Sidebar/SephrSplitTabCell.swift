import AppKit
import SephrKit

/// Sidebar representation of a split-tab group: the two split tabs shown
/// as one row of two side-by-side pills (favicon + title each), matching
/// the Zen-style combined pill. Clicking either half (re-)enters the
/// split view. The active pane reads brighter than the inactive one.
final class SephrSplitTabCell: NSView {

    let primary: SephrTab
    let secondary: SephrTab
    /// Tapped either half → enter / focus the split.
    var onSelect: (() -> Void)?

    private let primaryHalf: SephrSplitHalfView
    private let secondaryHalf: SephrSplitHalfView

    /// One subscription per member tab — each half refreshes on its own
    /// tab's events. Dropping the tokens unsubscribes.
    private var primaryToken: TabEventToken?
    private var secondaryToken: TabEventToken?

    init(primary: SephrTab, secondary: SephrTab) {
        self.primary = primary
        self.secondary = secondary
        self.primaryHalf = SephrSplitHalfView(tab: primary)
        self.secondaryHalf = SephrSplitHalfView(tab: secondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        primaryHalf.onClick = { [weak self] in self?.onSelect?() }
        secondaryHalf.onClick = { [weak self] in self?.onSelect?() }

        addSubview(primaryHalf)
        addSubview(secondaryHalf)

        // Manual layout rather than NSStackView: a horizontal stack only
        // offers .centerY/.top/.bottom alignment (no perpendicular fill),
        // so the halves would collapse to their ~16pt content height inside
        // the 30pt row and read as squished lozenges. Pinning each half's
        // top+bottom to the cell makes them full-height rounded pills, and
        // the equal-width constraint splits the row 50/50 with a small gap.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            primaryHalf.topAnchor.constraint(equalTo: topAnchor),
            primaryHalf.bottomAnchor.constraint(equalTo: bottomAnchor),
            primaryHalf.leadingAnchor.constraint(equalTo: leadingAnchor),

            secondaryHalf.topAnchor.constraint(equalTo: topAnchor),
            secondaryHalf.bottomAnchor.constraint(equalTo: bottomAnchor),
            secondaryHalf.leadingAnchor.constraint(
                equalTo: primaryHalf.trailingAnchor, constant: 5),
            secondaryHalf.trailingAnchor.constraint(equalTo: trailingAnchor),

            primaryHalf.widthAnchor.constraint(
                equalTo: secondaryHalf.widthAnchor),
        ])

        // `refresh()` paints favicon, title, and active-dim — nothing
        // else. Filter out `.loading`, `.audio`, `.media` since they
        // don't change any of the three. Without the filter, an audible
        // page playing inside a split pane was repainting the whole
        // split cell on every Chromium OnAudioStateChanged.
        let filter: (TabEvent) -> Bool = { e in
            switch e.kind {
            case .favicon, .title, .url, .active: return true
            case .loading, .audio, .media:        return false
            }
        }
        primaryToken = TabEventBus.shared.subscribe(tabID: primary.id) {
            [weak self] event in
            guard filter(event) else { return }
            self?.primaryHalf.refresh()
        }
        secondaryToken = TabEventBus.shared.subscribe(tabID: secondary.id) {
            [weak self] event in
            guard filter(event) else { return }
            self?.secondaryHalf.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One half of a `SephrSplitTabCell` — a glass pill with a tab's favicon
/// and (truncating) title, dimmed when the tab isn't the active pane.
final class SephrSplitHalfView: NSView {

    /// Shared globe fallback — was allocated per refresh; with two halves
    /// each subscribing to four event kinds, this could fire many times
    /// while watching a feed.
    private static let globeGlyph = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: nil)

    let tab: SephrTab
    var onClick: (() -> Void)?

    private let favicon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(tab: SephrTab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        layer?.masksToBounds = true

        let glass: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = DC.Radius.standard
            g.tintColor = nil
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = DC.Radius.standard
            v.layer?.masksToBounds = true
            glass = v
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Let the title shrink so two halves fit a narrow sidebar row.
        titleLabel.setContentCompressionResistancePriority(.defaultLow,
                                                           for: .horizontal)

        addSubview(favicon)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 14),
            favicon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if let img = tab.favicon {
            if favicon.image !== img { favicon.image = img }
            if favicon.contentTintColor != nil { favicon.contentTintColor = nil }
        } else {
            if favicon.image !== Self.globeGlyph { favicon.image = Self.globeGlyph }
            if favicon.contentTintColor !== NSColor.secondaryLabelColor {
                favicon.contentTintColor = .secondaryLabelColor
            }
        }
        let newTitle = tab.title.isEmpty ? tab.url : tab.title
        if titleLabel.stringValue != newTitle { titleLabel.stringValue = newTitle }
        // Active pane reads brighter, the other slightly dimmed.
        let wantedAlpha: CGFloat = tab.isActive ? 1.0 : 0.7
        if alphaValue != wantedAlpha { alphaValue = wantedAlpha }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
