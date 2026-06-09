import AppKit

protocol SephrSidebarViewDelegate: AnyObject {
    func sidebarDidSelectTab(_ tab: SephrTab)
    func sidebarDidSelectSplit(primary: SephrTab, secondary: SephrTab)
    func sidebarDidRequestNewTab()
    func sidebarDidRequestCommandBar()
    func sidebarDidRequestNewFolder()
    func sidebarDidRequestNewSpace()
    func sidebarWidthDidChange(_ newWidth: CGFloat)
}

/// Compact NSButton used for the top-of-sidebar collapse toggle. Lives
/// inline with the macOS traffic lights. Hover / press tints come from
/// the SephrHoverButton base.
final class SephrSidebarToggleButton: SephrHoverButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "sidebar.left",
                        accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 13, weight: .medium)
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class SephrSidebarView: NSView {

    weak var delegate: SephrSidebarViewDelegate?

    private let toggleButton  = SephrSidebarToggleButton()
    private let navStrip      = SephrSidebarNavStrip()
    let urlField              = SephrSidebarURLField()
    private let favoritesRow  = SephrFavoritesRow()
    private var spaceHeader:  SephrSpaceHeader!
    private let tabScrollView = NSScrollView()
    private let tabStackView  = NSStackView()
    private let footer        = SephrSidebarFooter()

    /// Overlay swapped in over the favorites / tab area when the user
    /// chooses "New Space" from the footer. Lazily created on first
    /// show; nil otherwise.
    private var createSpaceOverlay: SephrCreateSpaceView?

    /// True when the active space's folder list has been hidden via the
    /// space header's chevron. Persisted in-memory only (resets on
    /// relaunch) — the chevron is an in-session affordance.
    private var foldersCollapsed = false

    /// Last rendered structure key — IDs + flags that decide which
    /// cells exist and in what order. `.sephrTabModelChanged` fires
    /// for state-only updates too (active tab, title, favicon, loading)
    /// so without this guard `renderTabs()` would tear down and rebuild
    /// every cell on every keystroke a renderer commits. Cells already
    /// observe the notification themselves to refresh in place.
    private var lastStructureKey: String = ""

    /// Accumulator for 2-finger horizontal trackpad swipes. Once it
    /// crosses `swipeThreshold` the sidebar switches to the next /
    /// previous space and the accumulator resets. Reset on every
    /// non-changed phase so each gesture is one switch max.
    private var swipeAccum: CGFloat = 0
    private static let swipeThreshold: CGFloat = 90

    /// True while the pointer is anywhere inside the sidebar — drives the
    /// reveal of the URL bar's trailing copy / settings buttons. Works
    /// for both the docked sidebar and the floating overlay, since both
    /// are instances of this view.
    private var sidebarHovered = false

    private(set) var isCollapsed = false
    private(set) var isCompact: Bool

    /// True for the Arc-style hover overlay copy. Overlay instances
    /// ignore the persisted compact-mode preference (the floating card
    /// always renders at full width) and route their toggle-button taps
    /// through `onToggleSidebar` so the host can open the real sidebar
    /// instead of mutating the overlay's own state.
    private let isOverlay: Bool

    /// When set, the title-bar toggle button calls this instead of
    /// `toggleCollapse()` on self. Used by the floating overlay to
    /// expand the main sidebar and dismiss itself.
    var onToggleSidebar: (() -> Void)?

    static let fullWidth: CGFloat = 240
    static let compactWidth: CGFloat = 52
    static let collapsedWidth: CGFloat = 0

    /// CenterY constraints for the title-bar chrome strip — exposed so
    /// the window controller can pin them to the live traffic-light
    /// position (the actual macOS-version-dependent Y is read from
    /// `standardWindowButton(.closeButton).frame` at runtime).
    private var toggleCenterY: NSLayoutConstraint!
    private var navStripCenterY: NSLayoutConstraint!

    /// Default seed offset until the host calls `setChromeTopOffset(_:)`.
    private static let defaultChromeTopOffset: CGFloat = 12

    private var widthConstraint: NSLayoutConstraint? {
        constraints.first(where: { $0.firstAttribute == .width })
    }

    /// Aligns the toggle button + nav strip's vertical center with the
    /// macOS traffic lights. Called by `SephrWindowController` after the
    /// window is on screen, and again on resize.
    func setChromeTopOffset(_ y: CGFloat) {
        toggleCenterY?.constant = y
        navStripCenterY?.constant = y
    }

    init(asOverlay: Bool = false) {
        self.isOverlay = asOverlay
        self.isCompact = asOverlay ? false : SephrPreferences.sidebarCompact
        super.init(frame: .zero)
        setupAppearance()
        setupLayout()
        bindNotifications()
        renderAll()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Appearance

    private func setupAppearance() {
        wantsLayer = true
        // Sidebar is transparent — the window-wide NSGlassEffectView
        // backdrop provides the Liquid Glass material. A solid color
        // here would block it.
        layer?.backgroundColor = NSColor.clear.cgColor
        // Clip children to the sidebar's bounds so the chrome (toggle
        // button, nav strip, URL field) doesn't leak across the page
        // area when the sidebar animates to width=0 (collapsed state).
        layer?.masksToBounds = true
    }

    // MARK: — Layout

    private func setupLayout() {
        // Build the space header eagerly so the layout constraints
        // below have a concrete view to anchor. SephrSpaceManager is
        // @MainActor — NSView's init runs on the main thread, so this
        // access is safe.
        let currentSpace = MainActor.assumeIsolated {
            SephrSpaceManager.shared.currentSpace
        }
        spaceHeader = SephrSpaceHeader(
            space: currentSpace, isCollapsed: foldersCollapsed)
        spaceHeader.onToggleCollapse = { [weak self] in
            self?.toggleFoldersCollapse()
        }

        [toggleButton, navStrip, urlField, favoritesRow,
         spaceHeader, tabScrollView, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        // Stored centerY anchors for the title-bar row — the window
        // controller updates these once the window is on screen so the
        // chrome lines up with the macOS traffic lights regardless of
        // the version-dependent title-bar inset.
        toggleCenterY = toggleButton.centerYAnchor.constraint(
            equalTo: topAnchor, constant: Self.defaultChromeTopOffset)
        navStripCenterY = navStrip.centerYAnchor.constraint(
            equalTo: topAnchor, constant: Self.defaultChromeTopOffset)
        toggleCenterY.isActive = true
        navStripCenterY.isActive = true

        toggleButton.target = self
        // Match Cmd+S behavior: fully collapse / expand the sidebar.
        // Cmd+\ remains bound to the compact (narrow strip) preference.
        // Overlay instances route through onToggleSidebar so the host
        // controller can open the real sidebar.
        toggleButton.action = #selector(handleToggleButton)

        // Top-aligned scrollable column. The flipped document view makes
        // the stack grow top → down so the first tab sits at the top of
        // the sidebar (Arc/Zen) instead of dropping to the bottom-left
        // of NSScrollView's default non-flipped layout.
        let docContainer = SephrSidebarFlippedClip()
        docContainer.translatesAutoresizingMaskIntoConstraints = false
        docContainer.addSubview(tabStackView)
        // Wire the clip → stack reference so drop-target index math
        // can iterate the live arranged subviews.
        docContainer.hostStack = tabStackView
        tabScrollView.documentView = docContainer
        tabScrollView.hasVerticalScroller = true
        tabScrollView.scrollerStyle = .overlay
        tabScrollView.drawsBackground = false

        tabStackView.orientation = .vertical
        tabStackView.alignment = .leading
        tabStackView.spacing = 4
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabStackView.setHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            docContainer.topAnchor.constraint(
                equalTo: tabScrollView.contentView.topAnchor),
            docContainer.leadingAnchor.constraint(
                equalTo: tabScrollView.contentView.leadingAnchor),
            docContainer.trailingAnchor.constraint(
                equalTo: tabScrollView.contentView.trailingAnchor),
            docContainer.widthAnchor.constraint(
                equalTo: tabScrollView.contentView.widthAnchor),

            tabStackView.topAnchor.constraint(equalTo: docContainer.topAnchor),
            // Same 10pt rail as the divider above and the favorites row.
            // The cell's internal +10 favicon leading + 10 close-button
            // trailing gives a fully symmetric inner padding too.
            tabStackView.leadingAnchor.constraint(
                equalTo: docContainer.leadingAnchor, constant: 10),
            tabStackView.trailingAnchor.constraint(
                equalTo: docContainer.trailingAnchor, constant: -10),
            tabStackView.bottomAnchor.constraint(
                lessThanOrEqualTo: docContainer.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            // ── Top row: traffic-lights → sidebar toggle (left) │
            //              back / forward / reload (right) ──
            // macOS Tahoe puts the traffic-light centers at y≈10 from
            // the window top (4pt top inset + 6pt half-diameter). Both
            // controls anchor to that line so they read as a single
            // chrome strip across the window's title area, Arc-style.
            // Title-bar strip — only the toggle + nav buttons sit on the
            // traffic-light line. URL field goes back to its own row
            // underneath so it has room to breathe.
            toggleButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                // Overlay mode: traffic lights are shifted into the card
                // (see SephrWindowController.shiftTrafficLights), so the
                // toggle button gets a slightly bigger leading offset to
                // keep them from touching.
                constant: isOverlay ? 88 : 76),
            toggleButton.widthAnchor.constraint(equalToConstant: 22),
            toggleButton.heightAnchor.constraint(equalToConstant: 18),

            // navStrip needs an explicit width — its internal stack has
            // intrinsic 90pt (3 × 26pt buttons + 2 × 6pt gaps), but the
            // strip view itself has no leading constraint so AppKit
            // would otherwise collapse it to 0pt and render the buttons
            // outside the strip's bounds.
            // Nav strip's trailing matches the URL field's trailing (-12)
            // so the right-side inset mirrors the URL field's leading
            // inset (+12) — the title row reads symmetric across the
            // sidebar regardless of live width.
            navStrip.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: isOverlay ? -16 : -12),
            navStrip.widthAnchor.constraint(equalToConstant: 90),
            navStrip.heightAnchor.constraint(equalToConstant: 22),

            urlField.topAnchor.constraint(
                equalTo: topAnchor, constant: 38),
            urlField.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: isOverlay ? 16 : 12),
            urlField.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: isOverlay ? -16 : -12),
            urlField.heightAnchor.constraint(equalToConstant: 30),

            // Cross-space favorites sit at the top — pinned tabs are
            // not bound to any single space, so they read above the
            // space header rather than inside it. Height is left
            // intrinsic so the 4-column grid grows to 1, 2, or 3 rows
            // as more pins are added (capped at 12 visible).
            favoritesRow.topAnchor.constraint(
                equalTo: urlField.bottomAnchor, constant: 10),
            favoritesRow.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 10),
            favoritesRow.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),

            // Space header — symbol + name + collapse chevron. Same
            // 10pt rail as the rest of the column.
            spaceHeader.topAnchor.constraint(
                equalTo: favoritesRow.bottomAnchor, constant: 8),
            spaceHeader.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 10),
            spaceHeader.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),

            tabScrollView.topAnchor.constraint(
                equalTo: spaceHeader.bottomAnchor, constant: 6),
            tabScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),
        ])

        // Footer "+" picker — New Tab / New Folder / New Space.
        // New Space takes over the sidebar (in-place form) so the
        // user creates and stays inside the new space; New Folder
        // opens a popover with name + icon picker; New Tab routes
        // through the command bar.
        footer.onCreateTab = { [weak self] in
            self?.delegate?.sidebarDidRequestCommandBar()
        }
        footer.onCreateFolder = { [weak self] in
            self?.delegate?.sidebarDidRequestNewFolder()
        }
        footer.onCreateSpace = { [weak self] in
            self?.showCreateSpace()
        }
        // Footer space-pip clicks → switch to that space.
        footer.onSelectSpace = { space in
            MainActor.assumeIsolated {
                SephrSpaceManager.shared.switchToSpace(space)
            }
        }
        // A click on a favorite has to bubble through the same delegate
        // path as a regular tab cell — otherwise the model's active
        // flag flips but the host window controller never gets the
        // signal to swap the web view in. This is the bug fix for
        // "clicking a pinned tab doesn't open it".
        favoritesRow.onSelect = { [weak self] tab in
            self?.delegate?.sidebarDidSelectTab(tab)
        }
    }

    // MARK: — Collapse / Compact

    func collapse(animated: Bool = true) {
        guard !isCollapsed else { return }
        isCollapsed = true
        setWidth(Self.collapsedWidth, animated: animated)
    }

    /// Re-open the sidebar. Always restores the full width so the user
    /// isn't stuck in 52pt compact mode after a Cmd+S toggle — compact
    /// is a separate, sticky preference behind Cmd+\ and shouldn't be
    /// the "default open" state.
    func expand(animated: Bool = true) {
        guard isCollapsed else { return }
        isCollapsed = false
        if isCompact {
            isCompact = false
            SephrPreferences.sidebarCompact = false
            updateCompactAppearance()
        }
        setWidth(Self.fullWidth, animated: animated)
    }

    @objc func toggleCollapse() { isCollapsed ? expand() : collapse() }

    @objc private func handleToggleButton() {
        if let onToggleSidebar { onToggleSidebar(); return }
        toggleCollapse()
    }

    @objc func toggleCompactMode() {
        isCompact.toggle()
        SephrPreferences.sidebarCompact = isCompact
        setWidth(isCompact ? Self.compactWidth : Self.fullWidth, animated: true)
        updateCompactAppearance()
    }

    private func updateCompactAppearance() {
        favoritesRow.setCompact(isCompact)
        for v in tabStackView.arrangedSubviews {
            (v as? SephrTabCell)?.setCompact(isCompact)
            (v as? SephrFolderCell)?.setCompact(isCompact)
        }
    }

    private func setWidth(_ width: CGFloat, animated: Bool) {
        let block = {
            self.widthConstraint?.constant = width
            self.superview?.layoutSubtreeIfNeeded()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                block()
            }
        } else { block() }
        delegate?.sidebarWidthDidChange(width)
    }

    // MARK: — Rendering

    private func renderAll() {
        renderTabs()
        favoritesRow.reload()
        let space = MainActor.assumeIsolated {
            SephrSpaceManager.shared.currentSpace
        }
        spaceHeader.apply(space: space, isCollapsed: foldersCollapsed)
    }

    @objc private func renderTabs() {
        let space = SephrSpaceManager.shared.currentSpace
        let folders = SephrTabModel.shared.folders(in: space)
        let topLevelTabs = SephrTabModel.shared.tabs(in: space)
            .filter { $0.folderID == nil }

        // Structure key = anything that decides which cells exist or
        // in what order. Title / URL / favicon / active-tab changes
        // bypass this rebuild because they don't affect the key — the
        // cells themselves observe `.sephrTabModelChanged` and refresh
        // in place. With this guard, the common-case nav update
        // becomes a couple of NSTextField mutations instead of a
        // teardown + reallocation of every cell in the stack.
        //
        // We include each tab's folderID in the key because SephrFolderCell
        // re-reads its children only on init: a tab move between two
        // folders neither of which is top-level otherwise leaves the old
        // folder cell rendering the moved-out tab.
        var key = "\(foldersCollapsed ? "F" : "f")|\(isCompact ? "C" : "c")|"
        if !foldersCollapsed {
            for f in folders {
                key += "F:\(f.id.uuidString);"
            }
        }
        for t in topLevelTabs {
            key += "T:\(t.id.uuidString);"
        }
        for t in SephrTabModel.shared.allTabs where t.spaceID == space.id {
            if let fid = t.folderID {
                key += "M:\(t.id.uuidString)>\(fid.uuidString);"
            }
        }
        // The split group decides whether two cells collapse into one
        // combined pill, so it's part of the structure key.
        if let p = SephrSplitManager.shared.primaryID,
           let s = SephrSplitManager.shared.secondaryID {
            key += "SPLIT:\(p.uuidString)>\(s.uuidString);"
        }
        if key == lastStructureKey { return }
        lastStructureKey = key

        tabStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Folders only render when the space header's chevron is
        // expanded — collapsing it leaves a flat tab list, with no
        // empty divider hanging where the folder block would have been.
        if !foldersCollapsed {
            for folder in folders {
                let cell = SephrFolderCell(folder: folder)
                cell.delegate = self
                cell.setCompact(isCompact)
                tabStackView.addArrangedSubview(cell)
            }
            // Divider between folders and tabs — only shown when both
            // sides actually have content, so a folder-less or tab-less
            // space doesn't get a useless hairline.
            if !folders.isEmpty && !topLevelTabs.isEmpty {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                tabStackView.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(
                        equalTo: tabStackView.leadingAnchor),
                    sep.trailingAnchor.constraint(
                        equalTo: tabStackView.trailingAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        }

        // Tabs that belong to the active split group collapse into a single
        // combined pill (Zen-style), rendered at the position of whichever
        // member appears first. `rendered` tracks what's already been placed
        // so the second member is skipped.
        let split = SephrSplitManager.shared
        var rendered = Set<UUID>()
        for tab in topLevelTabs {
            if rendered.contains(tab.id) { continue }

            if split.contains(tab.id),
               let pid = split.primaryID, let sid = split.secondaryID,
               let p = topLevelTabs.first(where: { $0.id == pid }),
               let s = topLevelTabs.first(where: { $0.id == sid }) {
                let pill = SephrSplitTabCell(primary: p, secondary: s)
                pill.onSelect = { [weak self] in
                    self?.delegate?.sidebarDidSelectSplit(primary: p, secondary: s)
                }
                tabStackView.addArrangedSubview(pill)
                // Pin full width so the two halves share the row evenly.
                NSLayoutConstraint.activate([
                    pill.leadingAnchor.constraint(
                        equalTo: tabStackView.leadingAnchor),
                    pill.trailingAnchor.constraint(
                        equalTo: tabStackView.trailingAnchor),
                ])
                rendered.insert(pid)
                rendered.insert(sid)
                continue
            }

            let cell = SephrTabCell(tab: tab)
            cell.delegate = self
            cell.setCompact(isCompact)
            tabStackView.addArrangedSubview(cell)
            rendered.insert(tab.id)
        }
    }

    // MARK: — Folders-collapse

    private func toggleFoldersCollapse() {
        foldersCollapsed.toggle()
        let space = MainActor.assumeIsolated {
            SephrSpaceManager.shared.currentSpace
        }
        spaceHeader.apply(space: space, isCollapsed: foldersCollapsed)
        renderTabs()
    }

    // MARK: — Create-space takeover

    /// Slide a create-space form over the favorites/space-header/tab
    /// area. Chrome + footer stay visible. Caller wires onCreate /
    /// onCancel to dismiss + persist.
    func showCreateSpace() {
        guard createSpaceOverlay == nil else { return }
        let overlay = SephrCreateSpaceView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: .above, relativeTo: favoritesRow)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(
                equalTo: urlField.bottomAnchor, constant: 12),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
        // Hide the underlying space content; footer + chrome stay on
        // top to keep the user oriented.
        favoritesRow.isHidden = true
        spaceHeader.isHidden = true
        tabScrollView.isHidden = true

        overlay.onCancel = { [weak self] in self?.hideCreateSpace() }
        overlay.onCreate = { [weak self] result in
            guard let self else { return }
            let created = MainActor.assumeIsolated {
                SephrSpaceManager.shared.createSpace(
                    name: result.name,
                    symbolName: result.symbolName,
                    isolated: result.isolated)
            }
            MainActor.assumeIsolated {
                SephrSpaceManager.shared.switchToSpace(created)
            }
            self.hideCreateSpace()
        }
        createSpaceOverlay = overlay
        DispatchQueue.main.async { overlay.focusName() }
    }

    private func hideCreateSpace() {
        createSpaceOverlay?.removeFromSuperview()
        createSpaceOverlay = nil
        favoritesRow.isHidden = false
        spaceHeader.isHidden = false
        tabScrollView.isHidden = false
    }

    // MARK: — Hover (URL-bar action buttons)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setSidebarHovered(true) }
    override func mouseExited(with event: NSEvent)  { setSidebarHovered(false) }

    private func setSidebarHovered(_ hovered: Bool) {
        sidebarHovered = hovered
        if hovered {
            urlField.setActionsVisible(true)
        } else if !urlField.isSettingsPanelOpen {
            // Keep the buttons up while a settings popover is open so it
            // doesn't dangle from a button that's fading away.
            urlField.setActionsVisible(false)
        }
    }

    // MARK: — Swipe (2-finger trackpad) → space switch

    override func scrollWheel(with event: NSEvent) {
        // Only treat horizontal-dominant trackpad pans as space-switch
        // gestures; mouse-wheel scrolls (no scrollingDeltaX) and
        // vertical-dominant scrolls pass through to the scroll view.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas, abs(dx) > abs(dy) * 1.5
        else { super.scrollWheel(with: event); return }

        switch event.phase {
        case .began, .mayBegin: swipeAccum = 0
        case .changed:          swipeAccum += dx
        case .ended, .cancelled:
            commitSwipeIfPastThreshold(); swipeAccum = 0
        default: break
        }
        if event.momentumPhase == .ended { swipeAccum = 0 }
        // Commit mid-gesture too — feels snappier than waiting for
        // the user to lift their fingers.
        commitSwipeIfPastThreshold()
    }

    private func commitSwipeIfPastThreshold() {
        guard abs(swipeAccum) >= Self.swipeThreshold else { return }
        let direction = swipeAccum > 0 ? -1 : 1   // swipe right → prev
        swipeAccum = 0
        MainActor.assumeIsolated {
            SephrSpaceManager.shared.switchByOffset(direction)
        }
    }

    // MARK: — Notifications

    private func bindNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(renderTabs),
                       name: .sephrTabModelChanged, object: nil)
        nc.addObserver(self, selector: #selector(onSpaceChanged),
                       name: .sephrSpaceChanged, object: nil)
    }

    @objc private func onSpaceChanged() { renderAll() }

    // MARK: — Empty-space context menu

    /// Right-click on the empty sidebar background (anywhere that
    /// isn't a tab, favorite, or footer button) surfaces a quick
    /// "New …" menu — same actions as the footer "+" picker, just
    /// accessible from wherever the cursor happens to be. The flipped
    /// clip view inside the tab scroll area calls this too, so the
    /// menu also pops when the user right-clicks below the last tab.
    func showEmptySpaceMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Folder",
                     action: #selector(emptyMenuNewFolder),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Tab",
                     action: #selector(emptyMenuNewTab),
                     keyEquivalent: "t")
        menu.addItem(withTitle: "New Space",
                     action: #selector(emptyMenuNewSpace),
                     keyEquivalent: "")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Let cells handle their own right-click first. hitTest goes
        // through the subview tree; if anything but the sidebar itself
        // was hit, defer.
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit !== self {
            super.rightMouseDown(with: event)
            return
        }
        showEmptySpaceMenu(event)
    }

    @objc private func emptyMenuNewFolder() {
        delegate?.sidebarDidRequestNewFolder()
    }
    @objc private func emptyMenuNewTab() {
        delegate?.sidebarDidRequestCommandBar()
    }
    @objc private func emptyMenuNewSpace() {
        delegate?.sidebarDidRequestNewSpace()
    }
}

extension SephrSidebarView: SephrTabCellDelegate {
    func tabCellDidSelect(_ cell: SephrTabCell) {
        delegate?.sidebarDidSelectTab(cell.tab)
    }
    func tabCellDidClose(_ cell: SephrTabCell) {
        SephrTabModel.shared.closeTab(cell.tab)
    }
    func tabCellDidPin(_ cell: SephrTabCell) {
        SephrTabModel.shared.pinTab(cell.tab, pinned: !cell.tab.isPinned)
    }
}

extension SephrSidebarView: SephrFolderCellDelegate {
    func folderCellDidSelect(_ folder: SephrTabFolder, tab: SephrTab) {
        delegate?.sidebarDidSelectTab(tab)
    }
}

/// Coordinate-flipped container for an NSStackView inside an NSScrollView
/// document view so the stack grows top → down instead of bottom → up.
/// Doubles as the drop target for tab reordering — landing a drag here
/// (not on a folder cell) drops the tab at a top-level index computed
/// from the cursor's Y.
final class SephrSidebarFlippedClip: NSView {
    override var isFlipped: Bool { true }

    /// Stack the tabs/folders live in. The drop logic walks its
    /// arranged subviews to compute the insertion index from the
    /// drag's Y position.
    weak var hostStack: NSStackView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([SephrTabPasteboard.type])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Right-click on empty space below the last tab — bubble to the
    /// owning SephrSidebarView so the same "New Folder / New Tab /
    /// New Space" menu pops.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit !== self {
            super.rightMouseDown(with: event)
            return
        }
        var ancestor: NSView? = superview
        while let cur = ancestor {
            if let sb = cur as? SephrSidebarView {
                sb.showEmptySpaceMenu(event)
                return
            }
            ancestor = cur.superview
        }
        super.rightMouseDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo)
                                  -> NSDragOperation {
        SephrTabPasteboard.tabID(from: sender.draggingPasteboard) != nil
            ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo)
                                  -> NSDragOperation {
        SephrTabPasteboard.tabID(from: sender.draggingPasteboard) != nil
            ? .move : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let id = SephrTabPasteboard.tabID(
                from: sender.draggingPasteboard),
              let tab = SephrTabModel.shared.allTabs
                .first(where: { $0.id == id })
        else { return false }
        let space = SephrSpaceManager.shared.currentSpace
        let localY = convert(sender.draggingLocation, from: nil).y
        let targetIndex = computeTopLevelIndex(forY: localY)
        // A pinned chip dropped onto the tab list unpins — landing it in the
        // current space at the drop slot. A regular tab just reorders.
        if tab.isPinned {
            SephrTabModel.shared.unpinTab(tab, toIndex: targetIndex, in: space)
        } else {
            SephrTabModel.shared.moveTab(tab, toIndex: targetIndex, in: space)
        }
        return true
    }

    /// Translate a Y coordinate in the clip's flipped space into the
    /// target position within the SPACE's top-level tab list.
    /// Folder cells inside the stack are skipped — they're sibling
    /// drop targets that handle their own absorption.
    private func computeTopLevelIndex(forY y: CGFloat) -> Int {
        guard let stack = hostStack else { return 0 }
        var topLevelIndex = 0
        for view in stack.arrangedSubviews {
            // Use the cell's midY (in clip coords) as the split point.
            let mid = view.convert(
                NSPoint(x: 0, y: view.bounds.midY),
                to: self).y
            // Only tab cells count toward the top-level index — folders
            // and the separator are skipped.
            let isTopLevelTab = view is SephrTabCell
            if y < mid {
                return topLevelIndex
            }
            if isTopLevelTab { topLevelIndex += 1 }
        }
        return topLevelIndex
    }
}
