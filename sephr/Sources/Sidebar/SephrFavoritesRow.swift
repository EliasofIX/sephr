import AppKit

/// Grid of cross-space pinned tabs at the top of the sidebar.
///
/// Layout: each row *fills* the full sidebar width, divided equally by
/// the number of chips in that row — so 1 pin is one full-width chip,
/// 2 pins are halves, 3 are thirds, 4 are quarters. Beyond 4, pins wrap
/// into balanced rows of at most 4 (5 → 3+2, 6 → 3+3, 7 → 4+3, 8 → 4+4;
/// see `rowSplit`), up to 3 rows / 12 pins.
///
/// Every chip is the SAME size: a fixed `cellHeight`, with the width
/// coming from its row's `.fillEqually` division. Only the width changes
/// with pin count — the height (and the favicon inside it) never does.
///
/// In compact-sidebar mode (52pt strip) the grid would collapse to
/// useless slivers — so compact falls back to a single horizontal row
/// of the historic 28pt chip size.
final class SephrFavoritesRow: NSView {

    /// Hard ceiling — anything beyond this is silently clipped from the
    /// grid (still pinned in the model, just not rendered here).
    static let maxVisiblePins = 12
    /// Max chips per row. Rows are balanced under this — never more than
    /// `columns` in a row, and earlier rows take any remainder.
    static let columns = 4
    private static let cellSpacing: CGFloat = 6
    /// Fixed chip height. Width is the row's equal share of the sidebar,
    /// so chips stay this tall whether they're full-width or quarter-width.
    static let cellHeight: CGFloat = 40
    /// Favicon edge — sized off the fixed height (not the variable width)
    /// so the icon is identical across every chip regardless of count.
    static let faviconSize: CGFloat = 20
    /// Rounded-square mask for the favicon (~iOS app-icon proportion), so
    /// square favicons read as soft tiles rather than hard squares.
    static let faviconCornerRadius: CGFloat = 5

    /// Called when the user clicks a favorite. The sidebar wires this
    /// to its delegate so the host window controller can actually
    /// swap the web view in — without this hook the click only flips
    /// the `isActive` flag in the model and the page never loads.
    var onSelect: ((SephrTab) -> Void)?

    private let stack = NSStackView()
    private var compact = false
    private var lastKey: String = ""

    /// Thin caret painted between chips during a drag to show where the
    /// dropped (or reordered) pin will land. Frame-positioned manually in
    /// `dropSlot`; hidden whenever no drag is hovering.
    private let insertionBar = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.cellSpacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Accept tab drags so a regular sidebar tab can be dragged in to
        // pin it, and pinned chips can be dragged within the grid to
        // reorder. The drop slot + reorder math live in the dragging
        // destination extension below.
        registerForDraggedTypes([SephrTabPasteboard.type])

        insertionBar.wantsLayer = true
        insertionBar.layer?.backgroundColor =
            NSColor.controlAccentColor.cgColor
        insertionBar.layer?.cornerRadius = 1.5
        insertionBar.isHidden = true
        addSubview(insertionBar, positioned: .above, relativeTo: stack)

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .sephrTabModelChanged, object: nil)

        Task { @MainActor in reload() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCompact(_ compact: Bool) {
        guard self.compact != compact else { return }
        self.compact = compact
        lastKey = ""
        reload()
    }

    @MainActor @objc func reload() {
        let pinned = Array(
            SephrTabModel.shared.allPinnedTabs().prefix(Self.maxVisiblePins))
        var key = compact ? "C|" : "c|"
        for tab in pinned { key += "\(tab.id.uuidString);" }
        if key == lastKey { return }
        lastKey = key

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        insertionBar.isHidden = true

        if compact {
            renderCompact(pinned: pinned)
        } else if pinned.isEmpty {
            // No pins → render a placeholder so the row keeps a height and
            // is a visible drop target (an empty row is 0pt tall and can't
            // be dragged onto).
            renderEmptyPlaceholder()
        } else {
            renderGrid(pinned: pinned)
        }
    }

    /// Splits `count` pins into balanced rows of at most `columns`, with
    /// earlier rows taking any remainder: 1 → [1], 4 → [4], 5 → [3, 2],
    /// 6 → [3, 3], 7 → [4, 3], 8 → [4, 4], 12 → [4, 4, 4]. Each row then
    /// fills the sidebar width equally, so a row of N chips makes each
    /// 1/N wide while every chip keeps the same fixed height.
    static func rowSplit(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let rows = (count + columns - 1) / columns   // ceil(count / columns)
        let base = count / rows
        let extra = count % rows                      // first `extra` rows: +1
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Balanced rows, each `.fillEqually` so its chips split the full
    /// sidebar width evenly. No spacer padding — a row of 1 deliberately
    /// stretches that chip to full width (1 pin = full horizontal space).
    private func renderGrid(pinned: [SephrTab]) {
        var index = 0
        for rowCount in Self.rowSplit(count: pinned.count) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = Self.cellSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            for _ in 0..<rowCount {
                let tab = pinned[index]
                let cell = SephrFavoriteCell(tab: tab, compact: false)
                cell.onSelect = { [weak self] in self?.onSelect?(tab) }
                row.addArrangedSubview(cell)
                index += 1
            }
            stack.addArrangedSubview(row)
            // The row spans the full grid width — without an explicit
            // width-equal-to-stack anchor an NSStackView with `.leading`
            // alignment hugs its content and the columns end up at
            // intrinsic size instead of filling.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Compact: single horizontal row of small chips, intrinsic 28pt.
    /// The narrow strip can't usefully present a grid.
    private func renderCompact(pinned: [SephrTab]) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for tab in pinned {
            let cell = SephrFavoriteCell(tab: tab, compact: true)
            cell.onSelect = { [weak self] in self?.onSelect?(tab) }
            row.addArrangedSubview(cell)
        }
        stack.addArrangedSubview(row)
    }

    /// One-row dashed drop zone shown when nothing is pinned, so there's
    /// always somewhere to drag the first tab into. `dropSlot` skips it
    /// (it isn't an `NSStackView`) and falls back to index 0.
    private func renderEmptyPlaceholder() {
        let ph = SephrFavoritesPlaceholder()
        ph.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(ph)
        NSLayoutConstraint.activate([
            ph.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ph.heightAnchor.constraint(equalToConstant: Self.cellHeight),
        ])
    }
}

private final class SephrFavoriteCell: NSView {
    /// Click handler set by the host row. The row routes this up to
    /// the sidebar delegate so the window controller can actually
    /// show the tab — `SephrTabModel.activateTab` alone only flips
    /// the model flag, it doesn't swap the web view.
    var onSelect: (() -> Void)?

    private let tab: SephrTab
    private let image = NSImageView()
    private let compact: Bool
    private var hovered = false
    /// Liquid Glass surface behind the favicon (macOS 26+). Held as
    /// NSView so the availability-gated `NSGlassEffectView` type doesn't
    /// leak into the stored-property declaration. nil pre–macOS 26, where
    /// `refreshAppearance` falls back to the prior white-tinted layer.
    private var glassPill: NSView?

    /// Where the press started, in window coords. nil between gestures.
    private var mouseDownLocation: NSPoint?
    /// Set once a real drag has begun for this press, so `mouseUp` knows
    /// the gesture was a drag-to-reorder, not a tab-select click.
    private var dragInitiated = false
    /// Movement (pt) before a press becomes a drag instead of a click.
    /// Matches `SephrTabCell.dragSlop` — below this, sub-threshold trackpad
    /// jitter shouldn't tear the chip out and swallow the click.
    private static let dragSlop: CGFloat = 10

    init(tab: SephrTab, compact: Bool) {
        self.tab = tab
        self.compact = compact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Zen-style card corner radius — softer than the prior 8pt so
        // the chip reads as a discrete tile rather than a button.
        layer?.cornerRadius = 12
        installGlassPill()
        refreshAppearance()

        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        // Round the (square) favicon into a soft tile. Clipping to the
        // image view's square bounds rounds a favicon that fills it; the
        // high-res source from Chromium keeps the corners crisp.
        image.wantsLayer = true
        image.layer?.cornerRadius =
            compact ? 4 : SephrFavoritesRow.faviconCornerRadius
        image.layer?.masksToBounds = true
        addSubview(image)
        refreshFavicon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onTabModelChanged),
            name: .sephrTabModelChanged, object: nil)

        if compact {
            // Compact: fixed 28pt square — fits the 52pt-wide compact
            // sidebar with a few pixels of breathing room either side.
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 28),
                heightAnchor.constraint(equalToConstant: 28),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
        } else {
            // Full: cell width comes from the row's `.fillEqually`
            // distribution and varies with pin count, but the height is
            // FIXED so every chip is the same size. The favicon is sized
            // off that fixed height (not the variable width) so it stays
            // identical whether the chip is full-width or quarter-width.
            NSLayoutConstraint.activate([
                heightAnchor.constraint(
                    equalToConstant: SephrFavoritesRow.cellHeight),
                image.widthAnchor.constraint(
                    equalToConstant: SephrFavoritesRow.faviconSize),
                image.heightAnchor.constraint(
                    equalToConstant: SephrFavoritesRow.faviconSize),
            ])
        }

        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Defer selection to mouseUp so a press that turns into a drag
        // reorders instead of activating. (Was: activate immediately on
        // mouseDown, which made every reorder drag also switch tabs.)
        mouseDownLocation = event.locationInWindow
        dragInitiated = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !dragInitiated else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
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
        // the tab. activateTab flips the model flag; onSelect routes through
        // the sidebar delegate so the window controller swaps the web view
        // in (the flag alone doesn't repaint the content area).
        guard !dragInitiated, mouseDownLocation != nil else { return }
        SephrTabModel.shared.activateTab(tab)
        onSelect?()
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true; refreshAppearance()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; refreshAppearance()
    }

    /// Builds the Liquid Glass pill behind the favicon (macOS 26+),
    /// pinned to the cell bounds at the SAME 12pt corner radius so the
    /// tile keeps its exact size and shape — only its material changes to
    /// refracting glass (the soft light-bending edge runs down each side).
    /// Positioned BELOW the favicon so the glass reads as the tile and the
    /// icon floats on it. Pre–macOS 26 there's no glass and
    /// `refreshAppearance` falls back to the prior white-tinted layer.
    private func installGlassPill() {
        guard #available(macOS 26, *) else { return }
        let g = NSGlassEffectView(frame: .zero)
        g.cornerRadius = 12
        g.tintColor = nil
        g.translatesAutoresizingMaskIntoConstraints = false
        addSubview(g, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            g.topAnchor.constraint(equalTo: topAnchor),
            g.leadingAnchor.constraint(equalTo: leadingAnchor),
            g.trailingAnchor.constraint(equalTo: trailingAnchor),
            g.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glassPill = g
    }

    private func refreshAppearance() {
        if #available(macOS 26, *),
           let glass = glassPill as? NSGlassEffectView {
            // Glass mode: every pin is ALWAYS a refracting glass tile.
            // The active/hover state reads as a subtle brighten via the
            // glass tint — the side refraction stays on all four edges,
            // and the host layer stays clear so the glass is the only
            // surface painting behind the favicon.
            switch (tab.isActive, hovered) {
            case (true,  true):
                glass.tintColor = NSColor.white.withAlphaComponent(0.22)
            case (true,  false):
                glass.tintColor = NSColor.white.withAlphaComponent(0.16)
            case (false, true):
                glass.tintColor = NSColor.white.withAlphaComponent(0.10)
            case (false, false):
                glass.tintColor = nil
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        // Pre–macOS 26 fallback: Zen-style white-tinted card with a real
        // active state — active pin reads distinctly from idle/hover so the
        // user can spot which pin currently owns the content area.
        let alpha: CGFloat
        switch (tab.isActive, hovered) {
        case (true,  true):  alpha = 0.22
        case (true,  false): alpha = 0.18
        case (false, true):  alpha = 0.13
        case (false, false): alpha = 0.07
        }
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(alpha).cgColor
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Unpin",
                     action: #selector(unpin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(closeTab), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func unpin() {
        SephrTabModel.shared.pinTab(tab, pinned: false)
    }

    @objc private func closeTab() {
        SephrTabModel.shared.closeTab(tab)
    }

    private func refreshFavicon() {
        if let img = tab.favicon {
            image.image = img
            image.contentTintColor = nil
        } else {
            image.image = NSImage(systemSymbolName: "globe",
                                   accessibilityDescription: nil)
            image.contentTintColor = NSColor.secondaryLabelColor
        }
    }

    @objc private func onTabModelChanged() {
        refreshFavicon()
        // The active-tab flag may have flipped (user switched tabs);
        // re-tint so the pin's selected/idle state matches the model.
        refreshAppearance()
    }
}

extension SephrFavoriteCell: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                          sourceOperationMaskFor ctx: NSDraggingContext)
                          -> NSDragOperation {
        // .move drives reordering within the favorites grid (the grid's
        // drop target only accepts .move). .copy lets the content area
        // accept the same drag as an "open as split pane" gesture, exactly
        // like a regular sidebar tab cell — destinations intersect with
        // their own accepted mask.
        [.move, .copy]
    }
}

// MARK: — Drop target (pin / reorder)

extension SephrFavoritesRow {

    override func draggingEntered(_ sender: any NSDraggingInfo)
                                  -> NSDragOperation {
        guard SephrTabPasteboard.tabID(from: sender.draggingPasteboard) != nil
        else { return [] }
        return updateInsertion(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo)
                                  -> NSDragOperation {
        guard SephrTabPasteboard.tabID(from: sender.draggingPasteboard) != nil
        else { return [] }
        return updateInsertion(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        insertionBar.isHidden = true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        insertionBar.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertionBar.isHidden = true
        guard let id = SephrTabPasteboard.tabID(
                from: sender.draggingPasteboard),
              let tab = SephrTabModel.shared.allTabs
                .first(where: { $0.id == id })
        else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        SephrTabModel.shared.movePinnedTab(
            tab, toIndex: dropSlot(at: point).index)
        return true
    }

    /// Position + show the caret for the current drag location.
    private func updateInsertion(_ sender: any NSDraggingInfo)
                                 -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        insertionBar.frame = dropSlot(at: point).caret
        insertionBar.isHidden = false
        return .move
    }

    /// Maps a drop point to (insertion index over the visible pins, caret
    /// frame in self coords). Walks the balanced rows top→bottom and, in
    /// the row under the cursor, splits on each chip's horizontal midpoint.
    /// The placeholder (empty state) isn't an `NSStackView`, so it's
    /// skipped and the fallback index 0 is returned.
    private func dropSlot(at point: NSPoint) -> (index: Int, caret: NSRect) {
        let rows = stack.arrangedSubviews.compactMap { $0 as? NSStackView }
        var flat = 0
        for row in rows {
            let cells = row.arrangedSubviews
            if cells.isEmpty { continue }
            let rf = row.convert(row.bounds, to: self)
            // Above this row entirely → insert before its first chip.
            if point.y > rf.maxY {
                return (flat, caret(beforeLeadingOf: cells[0]))
            }
            // Within this row's vertical band → pick the slot by x.
            if point.y >= rf.minY {
                for cell in cells {
                    let f = cell.convert(cell.bounds, to: self)
                    if point.x < f.midX {
                        return (flat, caret(beforeLeadingOf: cell))
                    }
                    flat += 1
                }
                return (flat, caret(afterTrailingOf: cells[cells.count - 1]))
            }
            // Below this row → skip it, keep counting.
            flat += cells.count
        }
        // Past the last row → after the final chip (or origin if none).
        if let lastRow = rows.last(where: { !$0.arrangedSubviews.isEmpty }),
           let lastCell = lastRow.arrangedSubviews.last {
            return (flat, caret(afterTrailingOf: lastCell))
        }
        return (0, NSRect(x: 0, y: 0, width: 3, height: Self.cellHeight))
    }

    private func caret(beforeLeadingOf cell: NSView) -> NSRect {
        let f = cell.convert(cell.bounds, to: self)
        return NSRect(x: f.minX - Self.cellSpacing / 2 - 1.5,
                      y: f.minY, width: 3, height: f.height)
    }

    private func caret(afterTrailingOf cell: NSView) -> NSRect {
        let f = cell.convert(cell.bounds, to: self)
        return NSRect(x: f.maxX + Self.cellSpacing / 2 - 1.5,
                      y: f.minY, width: 3, height: f.height)
    }
}

/// Empty-state drop zone for the favorites row: a dashed rounded outline
/// with a faint hint. Purely visual — the enclosing `SephrFavoritesRow`
/// owns the actual drop handling.
private final class SephrFavoritesPlaceholder: NSView {
    private let border = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.separatorColor.cgColor
        border.lineDashPattern = [4, 3]
        border.lineWidth = 1
        layer?.addSublayer(border)

        let label = NSTextField(labelWithString: "Drag tabs here to pin")
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor.tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 10, cornerHeight: 10, transform: nil)
    }
}
