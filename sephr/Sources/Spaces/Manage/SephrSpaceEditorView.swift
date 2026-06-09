import AppKit

/// Compact editor shown in a popover from a column's pencil / "Edit…"
/// item. Edits name, icon, accent color, and isolated-profile flag, and
/// offers Delete. Changes are applied on "Done" (a transient popover that
/// dismisses on an outside click discards them) so we don't churn the
/// board on every keystroke.
final class SephrSpaceEditorView: NSView, NSTextFieldDelegate {

    var onCommit: ((SephrSpace) -> Void)?
    var onDelete: (() -> Void)?
    /// Wired by the hosting column to dismiss the popover after "Done".
    var onRequestClose: (() -> Void)?

    /// Working copy — controls mutate this; `commit()` publishes it.
    private var draft: SephrSpace

    private let nameField = NSTextField()
    private let symbolWell = SephrSymbolWell()
    private let isolatedToggle = NSButton(checkboxWithTitle: "Isolated profile",
                                          target: nil, action: nil)
    private var swatches: [SephrColorSwatch] = []
    private var pickerPopover: NSPopover?

    /// Preset accent palette — matches the spirit of the create-space
    /// flow's defaults.
    private static let palette = [
        "#7F8CFF", "#FF8FA3", "#9DE3C4", "#FFD479",
        "#C7A0FF", "#7FD4FF", "#FF9F7F", "#B0B7C3",
    ]

    init(space: SephrSpace) {
        self.draft = space
        super.init(frame: NSRect(x: 0, y: 0, width: 264, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Edit Space")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        symbolWell.symbolName = draft.resolvedSymbol
        symbolWell.onClick = { [weak self] in self?.presentSymbolPicker() }

        nameField.stringValue = draft.name
        nameField.placeholderString = "Space name…"
        nameField.font = .systemFont(ofSize: 13)
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commit)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSStackView(views: [symbolWell, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.alignment = .centerY

        // Color swatches.
        let colorLabel = NSTextField(labelWithString: "Color")
        colorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        colorLabel.textColor = .secondaryLabelColor

        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 6
        for hex in Self.palette {
            let sw = SephrColorSwatch(hex: hex)
            sw.isSelected = hex.caseInsensitiveCompare(draft.colorHex) == .orderedSame
            sw.onPick = { [weak self] picked in self?.selectColor(picked) }
            swatches.append(sw)
            swatchRow.addArrangedSubview(sw)
        }

        isolatedToggle.state = draft.useIsolatedProfile ? .on : .off
        isolatedToggle.target = self
        isolatedToggle.action = #selector(toggleIsolated)
        isolatedToggle.font = .systemFont(ofSize: 12)

        // Buttons.
        let doneButton = NSButton(title: "Done", target: self,
                                  action: #selector(commit))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let deleteButton = NSButton(title: "Delete", target: self,
                                    action: #selector(deleteTapped))
        deleteButton.bezelStyle = .rounded
        deleteButton.hasDestructiveAction = true
        deleteButton.isEnabled = SephrSpaceManager.shared.spaces.count > 1

        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSStackView(views: [deleteButton, buttonSpacer, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let column = NSStackView(views: [
            title, nameRow, colorLabel, swatchRow, isolatedToggle, buttonRow,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(6, after: colorLabel)
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            symbolWell.widthAnchor.constraint(equalToConstant: 30),
            symbolWell.heightAnchor.constraint(equalToConstant: 30),
            nameField.heightAnchor.constraint(equalToConstant: 24),
            nameRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    // MARK: — Actions

    private func selectColor(_ hex: String) {
        draft.colorHex = hex
        for sw in swatches {
            sw.isSelected = sw.hex.caseInsensitiveCompare(hex) == .orderedSame
        }
    }

    @objc private func toggleIsolated() {
        draft.useIsolatedProfile = (isolatedToggle.state == .on)
    }

    @objc private func commit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { draft.name = name }
        draft.symbolName = symbolWell.symbolName
        onCommit?(draft)
        onRequestClose?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }

    private func presentSymbolPicker() {
        let picker = SephrSymbolPicker()
        picker.selected = symbolWell.symbolName
        picker.onPick = { [weak self] symbol in
            self?.symbolWell.symbolName = symbol
            self?.draft.symbolName = symbol
            self?.pickerPopover?.close()
            self?.pickerPopover = nil
        }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            picker.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            picker.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
        ])
        let vc = NSViewController()
        vc.view = host
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.show(relativeTo: symbolWell.bounds, of: symbolWell, preferredEdge: .maxY)
        pickerPopover = pop
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { draft.name = name }
    }
}

/// Round color swatch used by the space editor.
final class SephrColorSwatch: NSView {
    let hex: String
    var onPick: ((String) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(hex: String) {
        self.hex = hex
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(hexString: hex) ?? .systemIndigo
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let circle = NSBezierPath(ovalIn: inset)
        color.setFill()
        circle.fill()
        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onPick?(hex) }
}
