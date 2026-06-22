import AppKit

/// Minimal vertical icon rail for the library overlay — Notes, Downloads,
/// Archive, Spaces, plus a back affordance at the bottom.
final class SephrLibraryRailView: NSView {

    var onSelect: ((SephrLibrarySection) -> Void)?
    var onBack: (() -> Void)?

    private(set) var selection: SephrLibrarySection = .spaces {
        didSet { refreshSelection() }
    }

    private var sectionButtons: [SephrLibrarySection: SephrLibraryRailButton] = [:]
    private let backButton = SephrHoverButton()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelection(_ section: SephrLibrarySection) {
        selection = section
    }

    // MARK: — Layout

    private func buildLayout() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for section in SephrLibrarySection.allCases {
            let btn = SephrLibraryRailButton(section: section)
            btn.onClick = { [weak self] in
                guard let self else { return }
                self.selection = section
                self.refreshSelection()
                self.onSelect?(section)
            }
            sectionButtons[section] = btn
            stack.addArrangedSubview(btn)
        }

        backButton.image = NSImage(systemSymbolName: "chevron.left",
                                   accessibilityDescription: "Back to browsing")
        backButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        backButton.contentTintColor = .secondaryLabelColor
        backButton.restAlpha = 0
        backButton.hoverAlpha = 0.10
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 68),

            stack.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            backButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            backButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            backButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        refreshSelection()
    }

    private func refreshSelection() {
        for (section, btn) in sectionButtons {
            btn.isSelected = section == selection
        }
    }

    @objc private func backClicked() { onBack?() }
}

// MARK: — Rail button

private final class SephrLibraryRailButton: NSView {

    let section: SephrLibrarySection
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet { refreshAppearance() }
    }

    private let highlight = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(section: SephrLibrarySection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = DC.Radius.standard
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        iconView.image = NSImage(systemSymbolName: section.systemIcon,
                                 accessibilityDescription: section.label)
        iconView.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.stringValue = section.label
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 60),
            heightAnchor.constraint(equalToConstant: 58),

            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.centerXAnchor.constraint(equalTo: centerXAnchor),
            highlight.widthAnchor.constraint(equalToConstant: 52),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            iconView.topAnchor.constraint(equalTo: highlight.topAnchor, constant: 7),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])

        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func refreshAppearance() {
        highlight.layer?.backgroundColor = isSelected
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        iconView.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }
}
