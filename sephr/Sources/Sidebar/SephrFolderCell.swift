import AppKit

protocol SephrFolderCellDelegate: AnyObject {
    func folderCellDidSelect(_ folder: SephrTabFolder, tab: SephrTab)
}

/// Clickable folder icon + title row — toggles expand/collapse.
private final class FolderHeaderRow: NSView {
    var onClick: (() -> Void)?

    private var hovered = false {
        didSet { if hovered != oldValue { refreshHover() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func refreshHover() {
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(hovered ? 0.10 : 0).cgColor
    }
}

final class SephrFolderCell: NSView {

    let folder: SephrTabFolder
    weak var delegate: SephrFolderCellDelegate?

    private let headerRow = FolderHeaderRow()
    private let folderIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let childStack = NSStackView()
    private var compact = false

    init(folder: SephrTabFolder) {
        self.folder = folder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        headerRow.onClick = { [weak self] in self?.toggle() }

        folderIcon.image = NSImage(systemSymbolName: folder.resolvedSymbol,
                                    accessibilityDescription: folder.name)
        folderIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        folderIcon.contentTintColor = folder.color
        folderIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = folder.name
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        // Plain dynamic `labelColor` (NOT `.withAlphaComponent`): applying
        // an alpha to a dynamic system color flattens it against the base
        // (light) appearance, so on the dark Liquid Glass chrome the title
        // rendered near-black and unreadable in dark mode. The URL field's
        // plain `labelColor` proves the dynamic value resolves bright here.
        titleLabel.textColor = NSColor.labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = 1
        childStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerRow)
        headerRow.addSubview(folderIcon)
        headerRow.addSubview(titleLabel)
        addSubview(childStack)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            headerRow.heightAnchor.constraint(equalToConstant: 22),

            folderIcon.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            folderIcon.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(
                equalTo: folderIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                equalTo: headerRow.trailingAnchor, constant: -4),

            childStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 8),
            childStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            childStack.topAnchor.constraint(
                equalTo: headerRow.bottomAnchor, constant: 2),
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
        // O(1) cached lookup instead of a full `allTabs` scan per folder.
        // The cache lives on SephrTabModel and invalidates on any
        // structural change.
        for tab in SephrTabModel.shared.tabs(inFolder: folder.id) {
            let cell = SephrTabCell(tab: tab)
            cell.delegate = self
            cell.setCompact(compact)
            childStack.addArrangedSubview(cell)
        }
    }

    @objc private func toggle() {
        folder.isExpanded.toggle()
        reload()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Defer to a child cell if the click landed on a tab inside the
        // folder — the tab cell has its own context menu.
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit !== self, hit !== headerRow,
           hit !== titleLabel, hit !== folderIcon {
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
    func tabCellDidDuplicate(_ cell: SephrTabCell) {
        SephrTabModel.shared.duplicateTab(cell.tab)
    }
    func tabCellDidCloseOthers(_ cell: SephrTabCell) {
        SephrTabModel.shared.closeOtherTabs(keeping: cell.tab)
    }
    func tabCellDidCloseToRight(_ cell: SephrTabCell) {
        SephrTabModel.shared.closeTabsBelow(cell.tab)
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
              let tab = SephrTabModel.shared.tab(withID: id)
        else { return false }
        SephrTabModel.shared.moveTab(tab, toFolder: folder)
        return true
    }
}
