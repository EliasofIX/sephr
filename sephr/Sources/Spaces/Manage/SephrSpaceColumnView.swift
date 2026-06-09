import AppKit

/// One space, rendered as a column on the Manage Spaces board. Tinted
/// with its own accent color. Shows the space's folders and tabs, is a
/// drop target for tabs / folders / other columns, and can itself be
/// dragged (by the footer handle) to reorder the spaces.
final class SephrSpaceColumnView: NSView {

    static let columnWidth: CGFloat = 240

    private let space: SephrSpace

    private let symbolView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let editButton = SephrHoverButton()
    private let bodyStack = NSStackView()
    private let dragHandle = SephrColumnDragHandle()
    private let overflowButton = SephrHoverButton()

    private var editorPopover: NSPopover?

    init(space: SephrSpace) {
        self.space = space
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        refreshBackground(highlighted: false)

        buildLayout()
        reloadRows()

        registerForDraggedTypes([
            SephrTabPasteboard.type,
            SephrFolderPasteboard.type,
            SephrSpacePasteboard.type,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Layout

    private func buildLayout() {
        widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        // Header — symbol, name, pencil.
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .white
        symbolView.image = NSImage(systemSymbolName: space.resolvedSymbol,
                                   accessibilityDescription: space.name)
        symbolView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)

        nameLabel.stringValue = space.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        editButton.image = NSImage(systemSymbolName: "pencil",
                                   accessibilityDescription: "Edit Space")
        editButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        editButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        editButton.target = self
        editButton.action = #selector(presentEditor)
        editButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [symbolView, nameLabel, editButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Body — scrollable list of folders + tabs.
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 4
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let bodyScroll = NSScrollView()
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.hasHorizontalScroller = false
        bodyScroll.verticalScrollElasticity = .allowed
        let bodyDoc = NSView()
        bodyDoc.translatesAutoresizingMaskIntoConstraints = false
        bodyDoc.addSubview(bodyStack)
        bodyScroll.documentView = bodyDoc

        // Footer — drag-to-reorder handle + overflow menu.
        dragHandle.onDrag = { [weak self] event in self?.beginColumnDrag(event) }

        overflowButton.image = NSImage(systemSymbolName: "ellipsis",
                                       accessibilityDescription: "Space options")
        overflowButton.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        overflowButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.translatesAutoresizingMaskIntoConstraints = false

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [dragHandle, footerSpacer, overflowButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(bodyScroll)
        addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            bodyScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            bodyScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bodyScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            bodyStack.topAnchor.constraint(equalTo: bodyDoc.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyDoc.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyDoc.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bodyDoc.bottomAnchor),
            bodyDoc.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),

            footer.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: — Rows

    private func reloadRows() {
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let model = SephrTabModel.shared
        let tabs = model.tabs(in: space)
        // Folders first, each followed by its member tabs (indented).
        for folder in model.folders(in: space) {
            addRow(.folder(folder))
            for tab in tabs where tab.folderID == folder.id {
                addRow(.tab(tab), indented: true)
            }
        }
        // Then loose tabs.
        for tab in tabs where tab.folderID == nil {
            addRow(.tab(tab))
        }
        if bodyStack.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "No tabs")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = NSColor.white.withAlphaComponent(0.4)
            bodyStack.addArrangedSubview(empty)
        }
    }

    private func addRow(_ content: SephrSpaceColumnRowView.Content,
                        indented: Bool = false) {
        let r = SephrSpaceColumnRowView(content: content,
                                        space: space,
                                        indented: indented)
        r.translatesAutoresizingMaskIntoConstraints = false
        // Add to the stack FIRST so `r` and `bodyStack` share an ancestor;
        // activating the width constraint before that throws an Auto Layout
        // "no common ancestor" exception — fatal here because the uncaught
        // ObjC exception unwinds through Chromium's run loop and kills the
        // whole app.
        bodyStack.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
    }

    // MARK: — Column drag (reorder spaces)

    private func beginColumnDrag(_ event: NSEvent) {
        let item = NSDraggingItem(
            pasteboardWriter: SephrSpacePasteboard.pasteboardItem(for: space))
        item.draggingFrame = bounds
        item.imageComponentsProvider = { [weak self] in
            guard let self else { return [] }
            let comp = NSDraggingImageComponent(key: .icon)
            comp.contents = self.snapshot()
            comp.frame = self.bounds
            return [comp]
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        img.unlockFocus()
        return img
    }

    // MARK: — Edit / delete

    @objc private func presentEditor() {
        let editor = SephrSpaceEditorView(space: space)
        editor.onCommit = { updated in
            SephrSpaceManager.shared.updateSpace(updated)
        }
        editor.onRequestClose = { [weak self] in
            self?.editorPopover?.performClose(nil)
        }
        editor.onDelete = { [weak self] in
            guard let self else { return }
            self.editorPopover?.performClose(nil)
            SephrSpaceManager.shared.deleteSpace(self.space)
        }
        let vc = NSViewController()
        vc.view = editor
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.contentSize = editor.fittingSize
        pop.show(relativeTo: editButton.bounds, of: editButton,
                 preferredEdge: .maxY)
        editorPopover = pop
    }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit…",
                              action: #selector(presentEditor), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let delete = NSMenuItem(title: "Delete Space",
                                action: #selector(deleteSpace), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = SephrSpaceManager.shared.spaces.count > 1
        menu.addItem(delete)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: overflowButton)
        }
    }

    @objc private func deleteSpace() {
        guard SephrSpaceManager.shared.spaces.count > 1 else { return }
        SephrSpaceManager.shared.deleteSpace(space)
    }

    // MARK: — Drop target

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        refreshBackground(highlighted: false)
    }

    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if SephrTabPasteboard.tabID(from: pb) != nil
            || SephrFolderPasteboard.folderID(from: pb) != nil {
            refreshBackground(highlighted: true)
            return .move
        }
        if let sid = SephrSpacePasteboard.spaceID(from: pb), sid != space.id {
            refreshBackground(highlighted: true)
            return .move
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { refreshBackground(highlighted: false) }
        let pb = sender.draggingPasteboard
        let model = SephrTabModel.shared

        if let id = SephrTabPasteboard.tabID(from: pb),
           let tab = model.allTabs.first(where: { $0.id == id }) {
            model.moveTab(tab, toSpace: space)
            return true
        }
        if let fid = SephrFolderPasteboard.folderID(from: pb),
           let folder = model.allFolders.first(where: { $0.id == fid }) {
            model.moveFolder(folder, toSpace: space)
            return true
        }
        if let sid = SephrSpacePasteboard.spaceID(from: pb), sid != space.id,
           let dragged = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == sid }),
           let destIndex = SephrSpaceManager.shared.spaces
            .firstIndex(where: { $0.id == space.id }) {
            SephrSpaceManager.shared.moveSpace(dragged, toIndex: destIndex)
            return true
        }
        return false
    }

    // MARK: — Appearance

    private func refreshBackground(highlighted: Bool) {
        let base = space.color.blended(withFraction: 0.35, of: .black) ?? space.color
        layer?.backgroundColor = base
            .withAlphaComponent(highlighted ? 0.95 : 0.78).cgColor
        layer?.borderWidth = highlighted ? 2 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
    }
}

extension SephrSpaceColumnView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
                         -> NSDragOperation {
        .move
    }
}

/// Small grab handle in a column footer. Starts a column-reorder drag
/// once the cursor moves past the threshold, mirroring the tab cell's
/// press-then-drag gesture so an ordinary click on the footer doesn't
/// tear the column out.
final class SephrColumnDragHandle: NSView {

    var onDrag: ((NSEvent) -> Void)?

    private let icon = NSImageView()
    private var mouseDownLocation: NSPoint?
    private var dragInitiated = false
    private static let dragSlop: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                             accessibilityDescription: "Move Space")
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        dragInitiated = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !dragInitiated else { return }
        let d = hypot(event.locationInWindow.x - start.x,
                      event.locationInWindow.y - start.y)
        guard d > Self.dragSlop else { return }
        dragInitiated = true
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        dragInitiated = false
    }
}
