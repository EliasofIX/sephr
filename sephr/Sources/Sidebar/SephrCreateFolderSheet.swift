import AppKit

/// Compact popover for creating OR editing a folder. Picks a name +
/// SF Symbol; color stays a soft default (see SephrTabModel) so the
/// folder reads as quiet chrome rather than a loud accent.
///
/// Pass `existing` to render in edit mode — the title flips to
/// "Rename Folder", the button reads "Save", and both fields prefill.
final class SephrCreateFolderSheet: NSViewController, NSTextFieldDelegate {

    var onCreate: ((String, String) -> Void)?  // (name, symbolName)
    var onCancel: (() -> Void)?

    private let existing: SephrTabFolder?

    private let nameField = NSTextField()
    private let symbolWell = SephrSymbolWell()
    private let createButton = NSButton(
        title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(
        title: "Cancel", target: nil, action: nil)
    private var chosenSymbol: String = "folder" {
        didSet { symbolWell.symbolName = chosenSymbol }
    }
    private var picker: NSPopover?

    init(existing: SephrTabFolder? = nil) {
        self.existing = existing
        super.init(nibName: nil, bundle: nil)
        if let f = existing {
            chosenSymbol = f.resolvedSymbol
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let isEditing = existing != nil
        let title = NSTextField(labelWithString:
            isEditing ? "Rename Folder" : "New Folder")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        symbolWell.symbolName = chosenSymbol
        symbolWell.onClick = { [weak self] in self?.showPicker() }

        nameField.placeholderString = "Folder name…"
        nameField.font = .systemFont(ofSize: 13)
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(createTapped)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        if let f = existing { nameField.stringValue = f.name }

        createButton.title = isEditing ? "Save" : "Create"

        let row = NSStackView(views: [symbolWell, nameField])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        createButton.target = self
        createButton.action = #selector(createTapped)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(title)
        v.addSubview(row)
        v.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(
                equalTo: v.trailingAnchor, constant: -14),

            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(
                equalTo: v.trailingAnchor, constant: -14),
            symbolWell.widthAnchor.constraint(equalToConstant: 32),
            symbolWell.heightAnchor.constraint(equalToConstant: 32),
            nameField.heightAnchor.constraint(equalToConstant: 28),

            buttons.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(
                equalTo: v.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(
                equalTo: v.bottomAnchor, constant: -12),

            v.widthAnchor.constraint(equalToConstant: 280),
        ])

        self.view = v
        validate()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func showPicker() {
        let picker = SephrSymbolPicker()
        picker.selected = chosenSymbol
        picker.onPick = { [weak self] s in
            self?.chosenSymbol = s
            self?.picker?.close()
            self?.picker = nil
        }
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
        pop.show(relativeTo: symbolWell.bounds,
                 of: symbolWell, preferredEdge: .maxY)
        self.picker = pop
    }

    @objc private func createTapped() {
        let n = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onCreate?(n, chosenSymbol)
    }
    @objc private func cancelTapped() { onCancel?() }

    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        createButton.isEnabled = !trimmed.isEmpty
    }
}
