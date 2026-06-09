import AppKit

protocol SephrFolderCellDelegate: AnyObject {
    func folderCellDidSelect(_ folder: SephrTabFolder, tab: SephrTab)
}

final class SephrFolderCell: NSView {

    let folder: SephrTabFolder
    weak var delegate: SephrFolderCellDelegate?

    private let disclosure = SephrHoverButton()
    private let folderIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let childStack = NSStackView()
    private var compact = false

    init(folder: SephrTabFolder) {
        self.folder = folder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        disclosure.image = NSImage(systemSymbolName:
            folder.isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        disclosure.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        disclosure.contentTintColor = NSColor.secondaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(toggle)

        folderIcon.image = NSImage(systemSymbolName: folder.resolvedSymbol,
                                    accessibilityDescription: folder.name)
        folderIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        folderIcon.contentTintColor = folder.color
        folderIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = folder.name
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.9)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = 1
        childStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosure)
        addSubview(folderIcon)
        addSubview(titleLabel)
        addSubview(childStack)

        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 4),
            disclosure.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            disclosure.widthAnchor.constraint(equalToConstant: 14),
            disclosure.heightAnchor.constraint(equalToConstant: 14),

            folderIcon.leadingAnchor.constraint(
                equalTo: disclosure.trailingAnchor, constant: 4),
            folderIcon.centerYAnchor.constraint(
                equalTo: disclosure.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(
                equalTo: folderIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(
                equalTo: disclosure.centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -8),

            childStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 22),
            childStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            childStack.topAnchor.constraint(
                equalTo: disclosure.bottomAnchor, constant: 2),
            childStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        Task { @MainActor in reload() }
        registerForDraggedTypes([SephrTabPasteboard.type])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCompact(_ compact: Bool) {
        self.compact = compact
        titleLabel.isHidden = compact
    }

    @MainActor private func reload() {
        childStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard folder.isExpanded else { return }
        for tab in SephrTabModel.shared.allTabs
            where tab.folderID == folder.id {
            let cell = SephrTabCell(tab: tab)
            cell.delegate = self
            cell.setCompact(compact)
            childStack.addArrangedSubview(cell)
        }
    }

    @objc private func toggle() {
        folder.isExpanded.toggle()
        disclosure.image = NSImage(systemSymbolName:
            folder.isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        reload()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Defer to a child cell if the click landed on a tab inside the
        // folder — the tab cell has its own context menu.
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit !== self, hit !== titleLabel,
           hit !== disclosure {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: folder.isExpanded ? "Collapse" : "Expand",
                     action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename Folder…",
                                action: #selector(renameFolder),
                                keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        let del = NSMenuItem(title: "Delete Folder",
                             action: #selector(deleteFolder),
                             keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameFolder() {
        let sheet = SephrCreateFolderSheet(existing: folder)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = sheet
        sheet.onCreate = { [weak self] newName, newSymbol in
            guard let self else { return }
            SephrTabModel.shared.updateFolder(
                self.folder, name: newName, symbolName: newSymbol)
            popover.close()
        }
        sheet.onCancel = { popover.close() }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    @objc private func deleteFolder() {
        // Tabs inside the folder are spilled into the top-level list of
        // the space (movingTabsTo: nil) so the user doesn't lose
        // anything they hadn't intended to drop.
        SephrTabModel.shared.deleteFolder(folder, movingTabsTo: nil)
    }
}

extension SephrFolderCell: SephrTabCellDelegate {
    func tabCellDidSelect(_ cell: SephrTabCell) {
        delegate?.folderCellDidSelect(folder, tab: cell.tab)
    }
    func tabCellDidClose(_ cell: SephrTabCell) {
        SephrTabModel.shared.closeTab(cell.tab)
    }
    func tabCellDidPin(_ cell: SephrTabCell) {
        SephrTabModel.shared.pinTab(cell.tab, pinned: !cell.tab.isPinned)
    }
}

// MARK: — Drop target — drag a tab onto a folder to move it inside

extension SephrFolderCell {
    override func draggingEntered(_ sender: any NSDraggingInfo)
                                  -> NSDragOperation {
        guard SephrTabPasteboard.tabID(
            from: sender.draggingPasteboard) != nil else { return [] }
        // Visual cue — tint the folder while a tab hovers over it so
        // the user knows the drop will land here.
        layer?.backgroundColor = folder.color
            .withAlphaComponent(0.18).cgColor
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { layer?.backgroundColor = NSColor.clear.cgColor }
        guard let id = SephrTabPasteboard.tabID(
            from: sender.draggingPasteboard),
              let tab = SephrTabModel.shared.allTabs
                .first(where: { $0.id == id })
        else { return false }
        SephrTabModel.shared.moveTab(tab, toFolder: folder)
        return true
    }
}
