import AppKit

/// Footer-row strip of space icons. Sits between the downloads chip on
/// the left and the "+" on the right. Each icon switches to its space
/// on click; a small dot pip floats under the currently-active one.
final class SephrSpaceSwitcherFooter: NSView {

    var onSelect: ((SephrSpace) -> Void)?
    var onCreate: (() -> Void)?  // chevron-plus inline if we ever need it

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: .sephrSpaceListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: .sephrSpaceChanged, object: nil)
        Task { @MainActor in self.rebuild() }
    }
    required init?(coder: NSCoder) { fatalError() }

    @MainActor @objc private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let current = SephrSpaceManager.shared.currentSpace
        for space in SephrSpaceManager.shared.footerSpaces() {
            let pip = SephrSpacePip(
                space: space, isActive: space.id == current.id)
            pip.onClick = { [weak self] in self?.onSelect?(space) }
            stack.addArrangedSubview(pip)
        }
    }
}

private final class SephrSpacePip: NSView {
    var onClick: (() -> Void)?
    private let space: SephrSpace
    private let isActive: Bool
    private let icon = NSImageView()
    private let dot = NSView()
    private var hovered = false { didSet { refresh() } }

    init(space: SephrSpace, isActive: Bool) {
        self.space = space
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        toolTip = space.name

        icon.image = NSImage(systemSymbolName: space.resolvedSymbol,
                              accessibilityDescription: space.name)
        icon.symbolConfiguration = .init(
            pointSize: SephrSidebarFooterMetrics.symbolPointSize,
            weight: .medium)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = NSColor.labelColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),
            heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: SephrSidebarFooterMetrics.iconCenterYOffset),
            icon.widthAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.iconBoxSize),
            icon.heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.iconBoxSize),
            dot.widthAnchor.constraint(equalToConstant: 4),
            dot.heightAnchor.constraint(equalToConstant: 4),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -3),
        ])
        refresh()
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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }
    override func mouseDown(with event: NSEvent)    { onClick?() }

    private func refresh() {
        icon.contentTintColor = isActive
            ? NSColor.labelColor
            : NSColor.secondaryLabelColor
        dot.isHidden = !isActive
        let alpha: CGFloat = hovered ? 0.10 : 0.0
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(alpha).cgColor
    }
}
