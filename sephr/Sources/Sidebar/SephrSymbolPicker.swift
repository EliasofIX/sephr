import AppKit

/// Curated grid of SF Symbols used by the space creator and the folder
/// creator. Pure presentation — the host hooks `onPick` and dismisses
/// itself. Keeping the catalog short (~30) keeps the grid scannable
/// without a search field; expand the list when the lineup outgrows it.
final class SephrSymbolPicker: NSView {

    /// Hand-picked SF Symbols that read well at 14–16pt and cover the
    /// most common space / folder topics. Order matters — left-to-right,
    /// top-to-bottom, grouped roughly by category.
    static let catalog: [String] = [
        // General
        "circle.hexagongrid", "globe.americas.fill", "sparkles",
        "leaf.fill", "star.fill", "moon.fill",
        // Personal / life
        "house.fill", "person.fill", "heart.fill", "bell.fill",
        // Work / productivity
        "briefcase.fill", "building.2.fill", "tray.full.fill",
        "doc.text.fill", "chart.bar.fill",
        // Creative
        "paintbrush.fill", "camera.fill", "music.note", "book.fill",
        "pencil",
        // Tech
        "cpu", "terminal.fill", "gearshape.fill", "lock.fill",
        // Travel / lifestyle
        "airplane", "car.fill", "graduationcap.fill",
        "dollarsign.circle.fill", "fork.knife", "gamecontroller.fill",
    ]

    var onPick: ((String) -> Void)?

    /// Currently-selected symbol — drawn with the accent ring so users
    /// see where the current value lives in the grid.
    var selected: String? {
        didSet { rebuild() }
    }

    private let stack = NSStackView()
    private let columns: Int

    init(columns: Int = 6) {
        self.columns = columns
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in stride(from: 0, to: Self.catalog.count, by: columns) {
            let r = NSStackView()
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = 6
            for col in 0..<columns where row + col < Self.catalog.count {
                let symbol = Self.catalog[row + col]
                r.addArrangedSubview(makeCell(symbol: symbol))
            }
            stack.addArrangedSubview(r)
        }
    }

    private func makeCell(symbol: String) -> NSView {
        let cell = SephrSymbolCell(symbol: symbol,
                                    isSelected: symbol == selected)
        cell.onClick = { [weak self] in
            self?.selected = symbol
            self?.onPick?(symbol)
        }
        return cell
    }
}

private final class SephrSymbolCell: NSView {
    var onClick: (() -> Void)?

    private let symbol: String
    private let imageView = NSImageView()
    private var hovered = false { didSet { refresh() } }
    private let isSelected: Bool

    init(symbol: String, isSelected: Bool) {
        self.symbol = symbol
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        imageView.image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: symbol)
        imageView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        imageView.contentTintColor = NSColor.labelColor.withAlphaComponent(0.85)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        let bg: CGColor
        if isSelected {
            bg = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
        } else if hovered {
            bg = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            bg = NSColor.clear.cgColor
        }
        layer?.backgroundColor = bg
    }
}
