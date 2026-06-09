import AppKit

protocol SephrTabCellDelegate: AnyObject {
    func tabCellDidSelect(_ cell: SephrTabCell)
    func tabCellDidClose(_ cell: SephrTabCell)
    func tabCellDidPin(_ cell: SephrTabCell)
}

final class SephrTabCell: NSView {

    /// EXPERIMENT — render the tab pill as an NSGlassEffectView (Liquid
    /// Glass) sitting behind the cell's content. Flip to `false` to
    /// revert to the previous white-tinted-layer pill in a single edit;
    /// both code paths live in `refreshAppearance()` below.
    private static let useGlassPill = true

    let tab: SephrTab
    weak var delegate: SephrTabCellDelegate?

    private let favicon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = SephrHoverButton()
    /// Optional glass surface — only created when `useGlassPill` is on.
    /// Held as NSView so we don't have to drag the NSGlassEffectView
    /// availability check through the property type.
    private var glassPill: NSView?
    private var hoverTimer: Timer?
    private var peekPopover: SephrPeekPopover?
    private var compact = false
    private var hovered = false

    init(tab: SephrTab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        installGlassPillIfEnabled()
        refreshAppearance()

        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.translatesAutoresizingMaskIntoConstraints = false
        refreshFavicon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onTabModelChanged),
            name: .sephrTabModelChanged, object: nil)

        titleLabel.stringValue = tab.title.isEmpty ? tab.url : tab.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark",
                                     accessibilityDescription: nil)
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.contentTintColor = NSColor.secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.alphaValue = 0

        [favicon, titleLabel, closeButton].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 14),
            favicon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Appearance

    func setCompact(_ compact: Bool) {
        self.compact = compact
        titleLabel.isHidden = compact
        closeButton.isHidden = compact
        refreshAppearance()
    }

    /// Builds the optional Liquid Glass pill surface and pins it to the
    /// cell's bounds. Pinned at z-order BELOW the favicon / title /
    /// close button so the glass reads as a backdrop, not an overlay.
    /// Pre–macOS 26 falls back to NSVisualEffectView so the experiment
    /// still has something to look at on Sequoia + earlier.
    private func installGlassPillIfEnabled() {
        guard Self.useGlassPill else { return }
        let surface: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: .zero)
            g.cornerRadius = 8
            g.tintColor = nil
            surface = g
        } else {
            let v = NSVisualEffectView(frame: .zero)
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 8
            v.layer?.masksToBounds = true
            surface = v
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.alphaValue = 0  // refreshAppearance() drives it
        addSubview(surface, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glassPill = surface
    }

    private func refreshAppearance() {
        if let glassPill {
            // Glass-pill mode: alpha modulates the glass surface's
            // visibility. Layer background stays clear so the glass is
            // the only thing painting behind the cell content.
            let alpha: CGFloat
            switch (tab.isActive, hovered) {
            case (true,  true):  alpha = 1.0
            case (true,  false): alpha = 0.85
            case (false, true):  alpha = 0.45
            case (false, false): alpha = 0.0
            }
            glassPill.alphaValue = alpha
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        // Fallback (useGlassPill = false): the previous white-tinted
        // layer pill. Arc-style — active reads as a discrete container,
        // hover on an inactive cell lights it up.
        let alpha: CGFloat
        switch (tab.isActive, hovered) {
        case (true,  true):  alpha = 0.16
        case (true,  false): alpha = 0.12
        case (false, true):  alpha = 0.07
        case (false, false): alpha = 0.0
        }
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(alpha).cgColor
    }

    private func refreshFavicon() {
        if let img = tab.favicon {
            favicon.image = img
            favicon.contentTintColor = nil  // let the icon paint itself
        } else {
            favicon.image = NSImage(systemSymbolName: "globe",
                                     accessibilityDescription: nil)
            favicon.contentTintColor = NSColor.secondaryLabelColor
        }
    }

    @objc private func onTabModelChanged() {
        // The active-tab pill must track selection. `activateTab` flips
        // `isActive` on the (reference-type) tabs in the model's array,
        // which doesn't republish the @Published array, so the sidebar
        // never rebuilds these cells on a plain tab switch — it relies on
        // this notification. Without refreshing appearance here the
        // highlight stayed stuck on the previously-active cell, making a
        // successful click look like it did nothing.
        refreshAppearance()
        refreshFavicon()
        let newTitle = tab.title.isEmpty ? tab.url : tab.title
        if titleLabel.stringValue != newTitle {
            titleLabel.stringValue = newTitle
        }
    }

    // MARK: — Events

    @objc private func close() { delegate?.tabCellDidClose(self) }

    /// Where the press started, in window coords. nil between gestures.
    private var mouseDownLocation: NSPoint?
    /// Set once a real drag-reorder session has begun for this press, so
    /// `mouseUp` knows the gesture was a drag, not a click.
    private var dragInitiated = false
    /// Movement (pt) the cursor must travel before a press becomes a
    /// drag-reorder instead of a tab-select click. The old 4pt slop was
    /// below typical trackpad click jitter, so ordinary clicks routinely
    /// crossed it, started a drag session, and were swallowed instead of
    /// selecting the tab — the "clicking a tab often does nothing" bug.
    /// 10pt matches AppKit's conventional drag threshold.
    private static let dragSlop: CGFloat = 10

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        dragInitiated = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !dragInitiated else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        // Only start a drag once the cursor has moved past the threshold —
        // short drift during a click shouldn't tear the cell out.
        guard hypot(dx, dy) > Self.dragSlop else { return }
        dragInitiated = true

        let item = NSDraggingItem(
            pasteboardWriter: SephrTabPasteboard.pasteboardItem(for: tab))
        item.draggingFrame = bounds
        item.imageComponentsProvider = { [weak self] in
            guard let self else { return [] }
            let comp = NSDraggingImageComponent(
                key: NSDraggingItem.ImageComponentKey.icon)
            comp.contents = self.snapshotImage()
            comp.frame = self.bounds
            return [comp]
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil; dragInitiated = false }
        // A press that never crossed the drag threshold is a click → select
        // the tab, regardless of any sub-threshold pointer drift.
        guard !dragInitiated, mouseDownLocation != nil else { return }
        delegate?.tabCellDidSelect(self)
    }

    private func snapshotImage() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        img.unlockFocus()
        return img
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: tab.isPinned ? "Unpin" : "Pin",
                     action: #selector(pin), keyEquivalent: "")
        menu.addItem(withTitle: "Close",
                     action: #selector(close), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func pin() { delegate?.tabCellDidPin(self) }

    // MARK: — Hover → Peek

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshAppearance()
        closeButton.animator().alphaValue = 1
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3,
                                           repeats: false) { [weak self] _ in
            guard let self else { return }
            let popover = SephrPeekPopover(tab: self.tab)
            popover.show(relativeTo: self.bounds, of: self,
                          preferredEdge: .maxX)
            self.peekPopover = popover
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshAppearance()
        closeButton.animator().alphaValue = 0
        hoverTimer?.invalidate()
        hoverTimer = nil
        peekPopover?.close()
        peekPopover = nil
    }
}

extension SephrTabCell: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                          sourceOperationMaskFor ctx: NSDraggingContext)
                          -> NSDragOperation {
        // .move drives sidebar reordering / folder absorption (those drop
        // targets only accept .move). .copy lets the content area accept
        // the same drag as a "open as second split pane" gesture — the
        // resolved op is the intersection with each destination's mask.
        [.move, .copy]
    }
}
