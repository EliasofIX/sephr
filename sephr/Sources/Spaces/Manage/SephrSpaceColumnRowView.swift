import AppKit

/// A single row inside a Manage Spaces column — either a folder header or
/// a tab. Tabs and folders are drag sources (so they can be dropped onto
/// another column); folder rows are also drop targets, so a tab can be
/// dragged directly into a folder, across spaces if needed.
final class SephrSpaceColumnRowView: NSView {

    enum Content {
        case folder(SephrTabFolder)
        case tab(SephrTab)
    }

    private let content: Content
    /// The space this row is rendered under — the destination when a tab
    /// is dropped into a folder living here.
    private let space: SephrSpace

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    private var mouseDownLocation: NSPoint?
    private var dragInitiated = false
    private static let dragSlop: CGFloat = 8

    init(content: Content, space: SephrSpace, indented: Bool) {
        self.content = content
        self.space = space
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.font = .systemFont(ofSize: 12)

        addSubview(iconView)
        addSubview(label)

        let leading: CGFloat = indented ? 22 : 8
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        configure()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        switch content {
        case .folder(let folder):
            iconView.image = NSImage(systemSymbolName: folder.resolvedSymbol,
                                     accessibilityDescription: folder.name)
            iconView.contentTintColor = folder.color
            label.stringValue = folder.name
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            registerForDraggedTypes([SephrTabPasteboard.type])

        case .tab(let tab):
            if let fav = tab.favicon {
                iconView.image = fav
                iconView.contentTintColor = nil
            } else {
                iconView.image = NSImage(systemSymbolName: "globe",
                                         accessibilityDescription: nil)
                iconView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            }
            label.stringValue = tab.title.isEmpty ? tab.url : tab.title
        }
    }

    // MARK: — Drag source

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

        let writer: NSPasteboardItem
        switch content {
        case .tab(let tab):    writer = SephrTabPasteboard.pasteboardItem(for: tab)
        case .folder(let folder): writer = SephrFolderPasteboard.pasteboardItem(for: folder)
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
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

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        dragInitiated = false
    }

    private func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            layer?.render(in: ctx)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        img.unlockFocus()
        return img
    }

    // MARK: — Folder drop target (tab → into this folder)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folderDropOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folderDropOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func folderDropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard case .folder(let folder) = content,
              SephrTabPasteboard.tabID(from: sender.draggingPasteboard) != nil
        else { return [] }
        layer?.backgroundColor = folder.color.withAlphaComponent(0.30).cgColor
        return .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { layer?.backgroundColor = NSColor.clear.cgColor }
        guard case .folder(let folder) = content,
              let id = SephrTabPasteboard.tabID(from: sender.draggingPasteboard),
              let tab = SephrTabModel.shared.allTabs.first(where: { $0.id == id })
        else { return false }
        // Carry the tab into this folder's space first if it came from a
        // different column, then drop it into the folder.
        if tab.spaceID != folder.spaceID {
            SephrTabModel.shared.moveTab(tab, toSpace: space)
        }
        SephrTabModel.shared.moveTab(tab, toFolder: folder)
        return true
    }
}

extension SephrSpaceColumnRowView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
                         -> NSDragOperation {
        .move
    }
}
