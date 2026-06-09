import AppKit

/// Sidebar-takeover form for creating a new space. The window controller
/// (or sidebar host) swaps this in where the favorites/folders/tabs
/// region normally lives — chrome (toggle/nav/URL) and footer stay
/// visible so the user keeps their bearings.
final class SephrCreateSpaceView: NSView, NSTextFieldDelegate {

    var onCreate: ((SephrCreateSpaceResult) -> Void)?
    var onCancel: (() -> Void)?

    private let nameField = SephrCenteredTextField()
    private let symbolButton = SephrSymbolWell()
    private let profileControl = NSSegmentedControl(
        labels: ["Shared", "Isolated"],
        trackingMode: .selectOne,
        target: nil, action: nil)
    private let createButton = NSButton(
        title: "Create Space", target: nil, action: nil)
    private let cancelButton = NSButton(
        title: "Cancel", target: nil, action: nil)

    /// Currently-chosen SF Symbol name; bound to the well + the
    /// transient picker popover.
    private var chosenSymbol: String = "circle.hexagongrid" {
        didSet { symbolButton.symbolName = chosenSymbol }
    }

    private var pickerPopover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildLayout()
        validate()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called when the view is shown so the name field grabs focus and
    /// the user can start typing immediately.
    func focusName() {
        window?.makeFirstResponder(nameField)
    }

    private func buildLayout() {
        // Heading
        let title = NSTextField(labelWithString: "Create a Space")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Separate your tabs for life, work, projects, and more.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 200
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // Name row: symbol well on the left, text field on the right.
        symbolButton.symbolName = chosenSymbol
        symbolButton.onClick = { [weak self] in self?.presentSymbolPicker() }

        nameField.placeholderString = "Space name…"
        nameField.font = .systemFont(ofSize: 13)
        nameField.isBordered = false
        nameField.drawsBackground = true
        nameField.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        nameField.focusRingType = .none
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(createTapped)
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 8

        let nameRow = NSStackView(views: [symbolButton, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.alignment = .centerY
        nameRow.translatesAutoresizingMaskIntoConstraints = false

        // Profile selector
        let profileLabel = NSTextField(labelWithString: "Profile")
        profileLabel.font = .systemFont(ofSize: 12, weight: .medium)
        profileLabel.textColor = .secondaryLabelColor
        profileLabel.translatesAutoresizingMaskIntoConstraints = false
        profileControl.selectedSegment = 0
        profileControl.translatesAutoresizingMaskIntoConstraints = false

        let profileRow = NSStackView(views: [profileLabel, profileControl])
        profileRow.orientation = .vertical
        profileRow.alignment = .leading
        profileRow.spacing = 6

        let profileHint = NSTextField(labelWithString:
            "Isolated spaces keep their own cookies and logins.")
        profileHint.font = .systemFont(ofSize: 10)
        profileHint.textColor = .tertiaryLabelColor
        profileHint.lineBreakMode = .byWordWrapping
        profileHint.maximumNumberOfLines = 2
        profileHint.preferredMaxLayoutWidth = 200
        profileHint.translatesAutoresizingMaskIntoConstraints = false

        // Buttons
        createButton.target = self
        createButton.action = #selector(createTapped)
        createButton.bezelStyle = .rounded
        createButton.controlSize = .large
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .accessoryBarAction
        cancelButton.isBordered = false
        cancelButton.keyEquivalent = "\u{1b}"  // Escape
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        // Master vertical stack
        let column = NSStackView(views: [
            title, subtitle, nameRow, profileRow, profileHint,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.setCustomSpacing(4, after: title)
        column.setCustomSpacing(2, after: profileRow)
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)
        addSubview(createButton)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12),

            symbolButton.widthAnchor.constraint(equalToConstant: 32),
            symbolButton.heightAnchor.constraint(equalToConstant: 32),
            nameField.heightAnchor.constraint(equalToConstant: 32),
            nameRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            profileControl.leadingAnchor.constraint(
                equalTo: column.leadingAnchor),
            profileControl.trailingAnchor.constraint(
                equalTo: column.trailingAnchor),

            // Anchor buttons to the bottom of the available area so
            // they read as the action footer of the form.
            createButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 12),
            createButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12),
            createButton.bottomAnchor.constraint(
                equalTo: cancelButton.topAnchor, constant: -8),

            cancelButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            cancelButton.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func presentSymbolPicker() {
        let picker = SephrSymbolPicker()
        picker.selected = chosenSymbol
        picker.onPick = { [weak self] symbol in
            self?.chosenSymbol = symbol
            self?.pickerPopover?.close()
            self?.pickerPopover = nil
        }
        // Wrap with margin so the popover doesn't crowd its edges.
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            picker.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -10),
            picker.bottomAnchor.constraint(
                equalTo: host.bottomAnchor, constant: -10),
        ])

        let vc = NSViewController()
        vc.view = host
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.show(relativeTo: symbolButton.bounds,
                 of: symbolButton,
                 preferredEdge: .maxY)
        pickerPopover = pop
    }

    @objc private func createTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let isolated = profileControl.selectedSegment == 1
        onCreate?(SephrCreateSpaceResult(
            name: name, symbolName: chosenSymbol, isolated: isolated))
    }

    @objc private func cancelTapped() { onCancel?() }

    func controlTextDidChange(_ obj: Notification) { validate() }

    private func validate() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        createButton.isEnabled = !trimmed.isEmpty
    }
}

/// Click target that renders the currently-chosen SF Symbol. Reused
/// by the create-folder sheet too.
final class SephrSymbolWell: NSView {
    var onClick: (() -> Void)?
    var symbolName: String = "circle.hexagongrid" { didSet { refresh() } }

    private let imageView = NSImageView()
    private var hovered = false { didSet { refreshBackground() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        imageView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        imageView.contentTintColor = NSColor.labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
        refreshBackground()
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
        imageView.image = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: symbolName)
    }
    private func refreshBackground() {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(hovered ? 0.14 : 0.08).cgColor
    }
}

struct SephrCreateSpaceResult {
    let name: String
    let symbolName: String
    let isolated: Bool
}

/// Text field whose contents (and placeholder) sit vertically centered.
/// A plain `NSTextField` top-aligns its single line inside a tall,
/// fixed-height frame, which leaves the "Space name…" placeholder
/// floating above the centerline next to the centered symbol well.
/// Overriding the cell class keeps AppKit's own field setup intact and
/// only swaps in the centering behavior.
final class SephrCenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SephrVerticallyCenteredTextFieldCell.self }
        set {}
    }
}

/// `NSTextFieldCell` that centers its single line of text within the
/// cell's bounds for both drawing and editing.
final class SephrVerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        var centered = rect
        centered.origin.y += (rect.height - textHeight) / 2
        centered.size.height = textHeight
        return centered
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView,
                     editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}
