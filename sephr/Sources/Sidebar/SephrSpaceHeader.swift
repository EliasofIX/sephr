import AppKit

/// Arc-style space header: SF Symbol + space name + collapse chevron.
/// The chevron toggles the visibility of every folder + tab below the
/// header (the host wires `onToggleCollapse` to do the actual hide).
final class SephrSpaceHeader: NSView {

    var onToggleCollapse: (() -> Void)?

    private(set) var space: SephrSpace
    private(set) var isCollapsed: Bool

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = SephrHoverButton()

    init(space: SephrSpace, isCollapsed: Bool) {
        self.space = space
        self.isCollapsed = isCollapsed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = NSColor.labelColor.withAlphaComponent(0.9)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = NSColor.secondaryLabelColor
        chevron.target = self
        chevron.action = #selector(toggle)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                equalTo: chevron.leadingAnchor, constant: -6),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 22),
            chevron.heightAnchor.constraint(equalToConstant: 22),
        ])

        apply(space: space, isCollapsed: isCollapsed)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Re-render the header with a new space and/or collapsed state.
    /// Used by the sidebar host when the user switches spaces or
    /// toggles the chevron — avoids tearing the view down.
    func apply(space: SephrSpace, isCollapsed: Bool) {
        self.space = space
        self.isCollapsed = isCollapsed
        icon.image = NSImage(systemSymbolName: space.resolvedSymbol,
                              accessibilityDescription: space.name)
        label.stringValue = space.name
        chevron.image = NSImage(systemSymbolName:
            isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil)
    }

    @objc private func toggle() { onToggleCollapse?() }
}
