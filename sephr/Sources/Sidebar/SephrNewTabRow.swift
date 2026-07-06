import AppKit

/// Arc-style "New Tab" action row pinned at the top of the per-space tab
/// list — below the cross-space favorites and the folder block, but the
/// first entry of the actual tab section. It mirrors a `SephrTabCell`'s
/// geometry (same 30pt height, same favicon → title rail) so it reads as
/// part of the list, while a "+" glyph and muted label mark it as an
/// action rather than a real tab. Clicking routes through the same path
/// as the footer's "+ → New Tab" (the command bar), so the user lands on
/// a URL / search prompt.
final class SephrNewTabRow: NSView {

    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New Tab")
    private var hovered = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard

        icon.image = NSImage(systemSymbolName: "plus",
                             accessibilityDescription: "New Tab")
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        // Dynamic `secondaryLabelColor` (never a baked alpha) so the row
        // stays a readable muted gray in both light and dark Liquid Glass.
        icon.contentTintColor = NSColor.secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        [icon, titleLabel].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            // Align the "+" with the shared icon rail (space header, folder
            // icons, and tab favicons all inset 8pt inside their cell).
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refreshBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Compact (icon-only) sidebar mode: drop the label, leave just the
    /// "+" on the favicon rail — same treatment the tab cells get.
    func setCompact(_ compact: Bool) {
        titleLabel.isHidden = compact
    }

    // MARK: — Hover

    func clearHoverState() {
        guard hovered else { return }
        hovered = false
        refreshBackground()
    }

    func syncHoverUnderPointer() {
        guard let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let shouldHover = bounds.contains(local)
        guard hovered != shouldHover else { return }
        hovered = shouldHover
        refreshBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isTabListHoverSuppressed else { return }
        hovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshBackground()
    }

    override func mouseUp(with event: NSEvent) {
        // Treat any click within the row as the action — there's nothing
        // to drag or select here, unlike a tab cell.
        onClick?()
    }

    /// Subtle white-over-glass hover tint matching the inactive-tab hover
    /// read; rest state is fully transparent so the row sits flat in the
    /// list until pointed at.
    private func refreshBackground() {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(hovered ? 0.07 : 0.0).cgColor
    }
}
