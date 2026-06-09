import AppKit

/// Horizontal row of space pills, rendered at the top of the sidebar.
/// Clicking a pill switches space; long-press opens the edit sheet.
final class SephrSpaceSwitcher: NSView {

    private let stackView = NSStackView()
    private let addButton = SephrHoverButton()
    private var compact = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        addButton.image = NSImage(systemSymbolName: "plus",
                                  accessibilityDescription: nil)
        addButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        addButton.contentTintColor = NSColor.secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addSpace)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .sephrSpaceListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .sephrSpaceChanged, object: nil)

        Task { @MainActor in reload() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCompact(_ compact: Bool) {
        self.compact = compact
        reload()
    }

    @MainActor @objc func reload() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let current = SephrSpaceManager.shared.currentSpace
        for space in SephrSpaceManager.shared.spaces {
            let pill = SephrSpacePill(space: space,
                                       isActive: space.id == current.id,
                                       compact: compact)
            pill.onClick = { SephrSpaceManager.shared.switchToSpace(space) }
            stackView.addArrangedSubview(pill)
        }
        stackView.addArrangedSubview(addButton)
    }

    @MainActor @objc private func addSpace() {
        _ = SephrSpaceManager.shared.createSpace(name: "New Space")
    }
}

private final class SephrSpacePill: NSView {
    var onClick: (() -> Void)?
    private let space: SephrSpace
    private let isActive: Bool
    private let label = NSTextField(labelWithString: "")
    private var hovered = false

    init(space: SephrSpace, isActive: Bool, compact: Bool) {
        self.space = space
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        refreshAppearance()

        label.stringValue = compact ? space.emoji : "\(space.emoji) \(space.name)"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = isActive ? .labelColor : NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

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
        hovered = true; refreshAppearance()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; refreshAppearance()
    }

    private func refreshAppearance() {
        // Active pill's space tint stays the dominant read; hover
        // brightens it. Inactive pills pick up a faint neutral tint on
        // hover so they don't look dead.
        let bg: CGColor
        switch (isActive, hovered) {
        case (true,  true):  bg = space.color.withAlphaComponent(0.50).cgColor
        case (true,  false): bg = space.color.withAlphaComponent(0.35).cgColor
        case (false, true):  bg = NSColor.white.withAlphaComponent(0.08).cgColor
        case (false, false): bg = NSColor.clear.cgColor
        }
        layer?.backgroundColor = bg
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let del = NSMenuItem(title: "Delete Space",
                             action: #selector(deleteSpace),
                             keyEquivalent: "")
        del.target = self
        // Last space stays — SephrSpaceManager refuses to delete it
        // anyway, but disabling the menu item makes that obvious.
        del.isEnabled = SephrSpaceManager.shared.spaces.count > 1
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteSpace() {
        SephrSpaceManager.shared.deleteSpace(space)
    }
}
