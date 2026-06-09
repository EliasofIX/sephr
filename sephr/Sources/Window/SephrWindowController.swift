import AppKit
import CAL

final class SephrWindowController: NSWindowController {

    private(set) var sidebarView: SephrSidebarView!
    private var contentHostView: SephrSplitDropView!
    private var splitController: SephrSplitViewController?
    private var activeWebView: CALWebView?
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var hoverEdge: SephrSidebarHoverEdge?
    private var resizer: SephrSidebarResizer?
    var createFolderPopover: NSPopover?
    private var resizeStartWidth: CGFloat = 0
    private var floatingSidebar: SephrFloatingSidebar?
    private var loadingBar: SephrLoadingBar?
    /// Arc-style link peek — a live floating web view of a Shift+hovered
    /// link, drawn over the page area. nil when no peek is showing.
    private var linkPeek: SephrLinkPeekOverlay?
    /// Local NSEvent monitor that watches for Shift+click on a link (to
    /// summon a peek of it) and Esc (to dismiss one).
    private var linkPeekMonitor: Any?

    /// Clamp range for live sidebar drag-resize. Below `minResizableWidth`
    /// the title-row toggle (76pt leading + 22pt width = 98pt to its
    /// trailing edge) and the nav strip (90pt wide + 12pt trailing inset
    /// = 102pt off the sidebar's right edge) start to collide; the 10pt
    /// margin between the two at this lower bound keeps the strip
    /// visually intact. Above `maxResizableWidth` the sidebar eats too
    /// much of the page area on a typical 1200pt window. Collapsed (0)
    /// and compact (52pt) are reachable via Cmd+S / Cmd+\ — the resizer
    /// never produces those states.
    private static let minResizableWidth: CGFloat = 210
    private static let maxResizableWidth: CGFloat = 500
    private var trafficLightsShifted = false
    /// Default vertical distance (in window coords, Y-down) from the
    /// window's top to the macOS close button's center. Captured once
    /// from a non-shifted state in `captureDefaultChromeY()` and used
    /// to align both the main sidebar's title row and the overlay's.
    private var defaultChromeY: CGFloat = 12
    /// Horizontal/vertical translation applied to the macOS traffic
    /// lights while the floating overlay is visible. Picks them up past
    /// the floating card's leading + top insets so they sit inside its
    /// chrome instead of in the window's title bar above it.
    private static let trafficLightOverlayShift = NSPoint(x: 12, y: -8)
    private static let trafficLightButtonTypes: [NSWindow.ButtonType] =
        [.closeButton, .miniaturizeButton, .zoomButton]

    convenience init() {
        let window = SephrWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Fully transparent window background so the macOS 26 Liquid
        // Glass surface installed in `setupViews` shows through behind
        // every Sephr chrome element (sidebar, URL field, content area).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.styleMask.insert(.fullSizeContentView)
        // Autosave restores the user's last window position + size on
        // every launch. `center()` would override the restored frame,
        // so only run it when no saved frame was loaded — i.e. the
        // very first launch.
        window.setFrameAutosaveName("SephrMainWindow")
        if !window.setFrameUsingName("SephrMainWindow") {
            window.center()
        }

        self.init(window: window)
        setupViews()
        SephrKeyboardShortcutMonitor.shared.register(in: self)
        restoreLastSpace()
    }

    deinit {
        if let m = linkPeekMonitor { NSEvent.removeMonitor(m) }
    }

    private func setupViews() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true

        // macOS 26 Liquid Glass — replaces the old NSVisualEffectView
        // sidebar material. NSGlassEffectView is the AppKit surface for
        // the new system material; fall back to NSVisualEffectView on
        // anything older so nightly Sequoia testers still see a sensible
        // background.
        let backdrop: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: cv.bounds)
            glass.cornerRadius = 0
            glass.tintColor = nil
            backdrop = glass
        } else {
            let v = NSVisualEffectView(frame: cv.bounds)
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .active
            backdrop = v
        }
        backdrop.autoresizingMask = [.width, .height]
        cv.addSubview(backdrop)

        // Zen-style: NO horizontal titlebar. Sidebar runs the full window
        // height (the traffic lights float over it because the window uses
        // .fullSizeContentView + titlebarAppearsTransparent). URL field
        // and nav buttons live inside the sidebar.
        sidebarView = SephrSidebarView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.delegate = self
        cv.addSubview(sidebarView)

        contentHostView = SephrSplitDropView()
        contentHostView.dropDelegate = self
        contentHostView.translatesAutoresizingMaskIntoConstraints = false
        contentHostView.wantsLayer = true
        // Transparent — the web page paints opaque pixels and the
        // surrounding window is Liquid Glass. White background was
        // making the entire content area look like a separate window.
        contentHostView.layer?.backgroundColor = NSColor.clear.cgColor
        contentHostView.layer?.cornerRadius = 10
        contentHostView.layer?.masksToBounds = true
        cv.addSubview(contentHostView)

        sidebarWidthConstraint = sidebarView.widthAnchor
            .constraint(equalToConstant: SephrPreferences.sidebarWidth)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: cv.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sidebarWidthConstraint,

            contentHostView.topAnchor.constraint(
                equalTo: cv.topAnchor, constant: 8),
            contentHostView.leadingAnchor.constraint(
                equalTo: sidebarView.trailingAnchor, constant: 8),
            contentHostView.trailingAnchor.constraint(
                equalTo: cv.trailingAnchor, constant: -8),
            contentHostView.bottomAnchor.constraint(
                equalTo: cv.bottomAnchor, constant: -8),
        ])

        // Loading shimmer pinned to the very top of the content area.
        // Sits inside contentHostView so it inherits the 10pt rounded
        // corner mask — the shimmer hugs the page rather than the raw
        // window edge.
        let bar = SephrLoadingBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentHostView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentHostView.topAnchor),
            bar.leadingAnchor.constraint(
                equalTo: contentHostView.leadingAnchor),
            bar.trailingAnchor.constraint(
                equalTo: contentHostView.trailingAnchor),
            bar.heightAnchor.constraint(
                equalToConstant: SephrLoadingBar.height),
        ])
        loadingBar = bar
        NotificationCenter.default.addObserver(
            self, selector: #selector(onTabLoadingChanged(_:)),
            name: .sephrTabLoadingChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPresentPopupPeek(_:)),
            name: .sephrPresentPopupPeek, object: nil)

        // Edge-hover trigger — narrow strip pinned to the window's left
        // edge that surfaces the Arc-style floating sidebar overlay while
        // the main sidebar is collapsed. Hidden until the sidebar is at
        // zero width so it never intercepts events otherwise.
        let edge = SephrSidebarHoverEdge()
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.isHidden = true
        cv.addSubview(edge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: cv.topAnchor),
            edge.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 8),
        ])
        edge.onMouseEntered = { [weak self] in self?.showFloatingSidebar() }
        self.hoverEdge = edge

        // Drag-to-resize handle, centered on the sidebar's trailing
        // edge. Lives in the same content view so it floats above both
        // the sidebar and the page area — the cursor needs a hit
        // surface on both sides of the visible boundary.
        let grip = SephrSidebarResizer()
        grip.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(grip, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            grip.topAnchor.constraint(equalTo: cv.topAnchor),
            grip.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            grip.centerXAnchor.constraint(
                equalTo: sidebarView.trailingAnchor),
            grip.widthAnchor.constraint(
                equalToConstant: SephrSidebarResizer.hitWidth),
        ])
        grip.onDragBegan = { [weak self] in
            guard let self else { return }
            self.resizeStartWidth = self.sidebarWidthConstraint.constant
        }
        grip.onDragChanged = { [weak self] dx in
            guard let self else { return }
            let raw = self.resizeStartWidth + dx
            let clamped = min(Self.maxResizableWidth,
                              max(Self.minResizableWidth, raw))
            // Direct constant assignment — no animator() — so the edge
            // tracks the cursor without lag. Traffic-light / hover-edge
            // state can't change inside the clamp range, so we skip
            // those reconciliations.
            self.sidebarWidthConstraint.constant = clamped
        }
        grip.onDragEnded = { [weak self] in
            guard let self else { return }
            SephrPreferences.sidebarWidth = self.sidebarWidthConstraint.constant
        }
        self.resizer = grip
        updateResizerVisibility()

        // We need to know when the window resizes so we can re-apply the
        // traffic-light translation — NSWindow re-lays out its standard
        // buttons during live resize and would otherwise snap them back
        // to their default positions while the overlay is visible.
        window?.delegate = self

        installLinkPeekMonitor()

        // The window's standard buttons aren't laid out until the next
        // run-loop pass, so defer the chrome alignment by one hop.
        DispatchQueue.main.async { [weak self] in
            self?.captureDefaultChromeY()
        }
    }

    /// Reads the macOS traffic-light center Y from the live window
    /// while it sits at its UNSHIFTED position and pushes it down to
    /// the main sidebar's title-row constraint. The overlay reuses the
    /// same default value: the floating card's 8pt top inset and the
    /// overlay-state's 8pt downward traffic-light shift cancel out, so
    /// `defaultChromeY` is correct for both surfaces. macOS-version
    /// independent — no hardcoded constant survives a change in
    /// title-bar metrics.
    private func captureDefaultChromeY() {
        guard !trafficLightsShifted else { return }
        guard let w = window,
              let btn = w.standardWindowButton(.closeButton),
              let frameView = btn.superview else { return }
        defaultChromeY = frameView.frame.height - btn.frame.midY
        sidebarView.setChromeTopOffset(defaultChromeY)
    }

    // MARK: — Floating overlay (collapsed-state hover)

    private func showFloatingSidebar() {
        guard floatingSidebar == nil, let cv = window?.contentView else {
            return
        }
        let fs = SephrFloatingSidebar(delegate: self)
        cv.addSubview(fs, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            fs.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            fs.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            fs.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            fs.widthAnchor.constraint(
                equalToConstant: SephrSidebarView.fullWidth),
        ])
        fs.onPointerExit = { [weak self] in self?.hideFloatingSidebar() }
        // Clicking the toggle inside the overlay opens the real sidebar
        // and dismisses the overlay — same gesture as Cmd+S.
        fs.sidebar.onToggleSidebar = { [weak self] in
            guard let self else { return }
            self.sidebarView.toggleCollapse()
            self.hideFloatingSidebar()
        }
        floatingSidebar = fs
        applyTrafficLightState()
        // Align the overlay's chrome with the (now-shifted) traffic
        // lights. The floating card's 8pt top inset cancels against the
        // 8pt downward shift applied to the buttons, so the same
        // `defaultChromeY` we use for the main sidebar lands the
        // overlay's toggle / nav strip on the lights' line.
        fs.sidebar.setChromeTopOffset(defaultChromeY)
        fs.slideIn()
    }

    private func hideFloatingSidebar() {
        guard let fs = floatingSidebar else { return }
        floatingSidebar = nil
        fs.slideOut { fs.removeFromSuperview() }
        applyTrafficLightState()
    }

    // MARK: — Traffic-light chrome

    /// Reconciles traffic-light visibility + position against the current
    /// sidebar state. Three states:
    ///   - Sidebar expanded:                 visible, default position
    ///   - Sidebar collapsed, no overlay:    hidden (no window chrome
    ///                                       floating over a blank page)
    ///   - Sidebar collapsed, overlay shown: visible, shifted so they
    ///                                       sit inside the floating card
    private func applyTrafficLightState() {
        guard let w = window else { return }
        let collapsed = sidebarWidthConstraint.constant <= 0
        let overlayVisible = floatingSidebar != nil
        let shouldShow = !collapsed || overlayVisible
        let shouldShift = collapsed && overlayVisible

        for type in Self.trafficLightButtonTypes {
            if let btn = w.standardWindowButton(type) {
                btn.isHidden = !shouldShow
            }
        }
        setTrafficLightsShifted(shouldShift)
    }

    private func setTrafficLightsShifted(_ shifted: Bool) {
        guard let w = window, shifted != trafficLightsShifted else { return }
        let sign: CGFloat = shifted ? 1 : -1
        for type in Self.trafficLightButtonTypes {
            guard let btn = w.standardWindowButton(type) else { continue }
            let o = btn.frame.origin
            btn.setFrameOrigin(NSPoint(
                x: o.x + sign * Self.trafficLightOverlayShift.x,
                y: o.y + sign * Self.trafficLightOverlayShift.y))
        }
        trafficLightsShifted = shifted
    }

    private func reapplyTrafficLightShiftIfNeeded() {
        guard trafficLightsShifted, let w = window else { return }
        // NSWindow re-lays its buttons during live resize, snapping them
        // back to default. Pretend the shift was never applied (so the
        // bookkeeping flips back to false), then re-apply.
        trafficLightsShifted = false
        setTrafficLightsShifted(true)
        // Also re-assert visibility, in case the layout pass un-hid them.
        let collapsed = sidebarWidthConstraint.constant <= 0
        let overlayVisible = floatingSidebar != nil
        let shouldShow = !collapsed || overlayVisible
        for type in Self.trafficLightButtonTypes {
            w.standardWindowButton(type)?.isHidden = !shouldShow
        }
    }

    // MARK: — Tab display

    /// Bridge → SephrTab.onLoading fires when the active page's
    /// loading flag flips. We only want to drive the shimmer for the
    /// tab currently on screen (background tabs may load too — peek
    /// thumbnails, prefetches, etc.).
    @objc private func onTabLoadingChanged(_ note: Notification) {
        guard let tab = note.object as? SephrTab,
              tab.id == SephrTabModel.shared.activeTab()?.id else { return }
        loadingBar?.setLoading(tab.isLoading)
    }

    func showTab(_ tab: SephrTab) {
        // The outgoing view stays attached while its thumbnail is being
        // captured — see `swapInTab(...)`. Detaching synchronously
        // would tear the renderer's compositor down before
        // `CopyFromSurface` could return real pixels, which is exactly
        // why peeks on inactive tabs were coming back blank.
        let outgoingView = activeWebView
        let outgoingTab = outgoingView.flatMap { v in
            SephrTabModel.shared.allTabs.first(where: { $0.webView === v })
        }

        splitController?.view.removeFromSuperview()
        splitController = nil

        let wv = tab.getOrCreateWebView()
        wv.frame = contentHostView.bounds
        wv.autoresizingMask = [.width, .height]
        // Add the new view on top of the old one. AppKit z-orders
        // subviews by insertion, so the new opaque page covers the
        // outgoing view visually while its renderer keeps painting in
        // the background — keeping the compositor alive long enough
        // for a clean snapshot.
        contentHostView.addSubview(wv)
        activeWebView = wv

        captureThenDetach(outgoingView: outgoingView,
                          outgoingTab: outgoingTab)
        // Sync the loading bar to the incoming tab's current state —
        // otherwise switching between a loading and an idle tab would
        // leave the shimmer in the wrong state until the next signal.
        loadingBar?.setLoading(tab.isLoading)
        // Don't call unfreeze/focus eagerly. SetPageFrozen + Focus on a
        // WebContents that hasn't completed its initial navigation
        // crashes (DCHECK in renderer host). Re-enable once the renderer
        // explicitly signals it's ready — Phase 4 work.
    }

    /// Triggers an async page-thumbnail capture on the outgoing view,
    /// stores the result on its owning tab, then removes the view from
    /// its superview. A 2-second fallback ensures detachment even if
    /// the capture never reports back (e.g. the renderer is dead).
    private func captureThenDetach(outgoingView: CALWebView?,
                                   outgoingTab: SephrTab?) {
        guard let outgoingView else { return }
        guard let outgoingTab, outgoingView.window != nil else {
            outgoingView.removeFromSuperview()
            return
        }
        let size = NSSize(width: 400, height: 260)
        var detached = false
        let detach: () -> Void = { [weak outgoingView] in
            if detached { return }
            detached = true
            outgoingView?.removeFromSuperview()
        }
        outgoingView.captureThumb(with: size) { img in
            if let img { outgoingTab.thumbnail = img }
            detach()
        }
        // Watchdog — if Chromium's CopyFromSurface never calls back
        // (process gone, ICE'd compositor, etc.), still detach.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            detach()
        }
    }

    func showSplit(primary: SephrTab, secondary: SephrTab) {
        // Idempotent — tear down any existing split or single view first so
        // re-entering the split (e.g. clicking the sidebar split pill) never
        // stacks controllers/web views.
        splitController?.view.removeFromSuperview()
        splitController = nil
        activeWebView?.removeFromSuperview()
        activeWebView = nil

        // Record the persistent group so the sidebar renders the combined
        // pill and the gesture refuses to start a second split.
        SephrSplitManager.shared.setGroup(primary: primary.id,
                                          secondary: secondary.id)

        let controller = SephrSplitViewController(primary: primary,
                                                   secondary: secondary)
        controller.onExpand = { [weak self] tab in
            guard let self else { return }
            // Break the group and promote the clicked pane to a full tab.
            SephrSplitManager.shared.clear()
            SephrTabModel.shared.activateTab(tab)
            self.showTab(tab)
        }
        // NSWindowController has no addChild — the controller is retained
        // via the `splitController` property and its view is added as a
        // subview, which is sufficient for AppKit lifecycle. Responder
        // chain wiring happens implicitly via nextResponder.
        controller.view.frame = contentHostView.bounds
        controller.view.autoresizingMask = [NSView.AutoresizingMask.width,
                                            NSView.AutoresizingMask.height]
        contentHostView.addSubview(controller.view)
        splitController = controller
    }

    // MARK: — Space restoration

    private func restoreLastSpace() {
        let space = SephrSpaceManager.shared.currentSpace
        SephrSpaceThemeEngine.shared.apply(space)
        if let active = SephrTabModel.shared.tabs(in: space)
            .first(where: { $0.isActive })
            ?? SephrTabModel.shared.tabs(in: space).first {
            showTab(active)
            return
        }
        // No prior tabs: open a default so the window isn't blank.
        // about:blank avoids any first-load crash; the user types a real
        // URL in the sidebar URL field to actually go somewhere.
        let initial = SephrTabModel.shared.newTab(in: space,
                                                  url: "https://example.com")
        showTab(initial)
    }
}

extension SephrWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        reapplyTrafficLightShiftIfNeeded()
        captureDefaultChromeY()
        persistFrame()
    }
    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        reapplyTrafficLightShiftIfNeeded()
        captureDefaultChromeY()
        persistFrame()
    }

    /// NSWindow's built-in frame autosave is lazy — it writes through
    /// the standard UserDefaults sync cadence and may be lost if the
    /// app exits abnormally (Chromium overrides SIGTERM, so anything
    /// other than a Cocoa Cmd+Q can skip the autosave flush). Saving
    /// explicitly on every resize/move + synchronizing defaults
    /// guarantees the latest frame is on disk before the next launch.
    private func persistFrame() {
        guard let window else { return }
        window.saveFrame(usingName: "SephrMainWindow")
        UserDefaults.standard.synchronize()
    }
}

extension SephrWindowController: SephrSplitDropViewDelegate {
    func splitDropView(_ view: SephrSplitDropView,
                       canSplitWith tabID: UUID) -> Bool {
        // Need an active tab to anchor the left pane, a *different* tab to
        // drop on the right, and no split already up. The dropped tab must
        // still exist in the model (the drag could outlive a close).
        guard splitController == nil,
              !SephrSplitManager.shared.hasGroup,   // one split group at a time
              let active = SephrTabModel.shared.activeTab(),
              active.id != tabID,
              SephrTabModel.shared.allTabs.contains(where: { $0.id == tabID })
        else { return false }
        return true
    }

    func splitDropView(_ view: SephrSplitDropView,
                       didRequestSplitWith tabID: UUID) {
        guard let primary = SephrTabModel.shared.activeTab(),
              let secondary = SephrTabModel.shared.allTabs
                .first(where: { $0.id == tabID }),
              primary.id != secondary.id
        else { return }
        showSplit(primary: primary, secondary: secondary)
    }
}

extension SephrWindowController: SephrSidebarViewDelegate {
    func sidebarDidSelectTab(_ tab: SephrTab) {
        SephrTabModel.shared.activateTab(tab)
        showTab(tab)
    }

    func sidebarDidSelectSplit(primary: SephrTab, secondary: SephrTab) {
        // Clicking the combined sidebar pill (re-)enters the split view.
        // Keep the primary marked active so its pane reads as focused.
        SephrTabModel.shared.activateTab(primary)
        showSplit(primary: primary, secondary: secondary)
    }

    func sidebarDidRequestNewTab() {
        let space = SephrSpaceManager.shared.currentSpace
        _ = SephrTabModel.shared.newTab(in: space)
    }

    func sidebarDidRequestCommandBar() {
        SephrCommandBar.show(in: self)
    }

    func sidebarDidRequestNewFolder() {
        // Pop the create-folder sheet relative to the footer's "+"
        // button so it reads as a satellite of the action that opened
        // it. The sheet collects name + SF Symbol; the space's accent
        // color tints the folder so it visually belongs to the space.
        let sheet = SephrCreateFolderSheet()
        sheet.onCreate = { [weak self] name, symbol in
            guard let self else { return }
            let space = SephrSpaceManager.shared.currentSpace
            // Lets SephrTabModel apply its softer default folder
            // color instead of inheriting the space's saturated tint.
            _ = SephrTabModel.shared.createFolder(
                name: name,
                symbolName: symbol,
                in: space)
            self.dismissCreateFolderPopover()
        }
        sheet.onCancel = { [weak self] in self?.dismissCreateFolderPopover() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = sheet
        if let anchor = sidebarView {
            popover.show(relativeTo: anchor.bounds,
                         of: anchor, preferredEdge: .maxX)
        }
        createFolderPopover = popover
    }

    private func dismissCreateFolderPopover() {
        createFolderPopover?.close()
        createFolderPopover = nil
    }

    func sidebarDidRequestNewSpace() {
        // Now routed inside the sidebar via SephrSidebarView.showCreateSpace
        // — this delegate stub is kept for protocol conformance and
        // forwards to the takeover flow in case any other caller still
        // requests the legacy modal path.
        sidebarView?.showCreateSpace()
    }

    func sidebarWidthDidChange(_ w: CGFloat) {
        SephrPreferences.sidebarWidth = w
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebarWidthConstraint.animator().constant = w
        }
        // Sidebar collapsed → arm the edge-hover trigger. Sidebar opened
        // back up → disarm and tear down any in-flight overlay.
        let collapsed = w <= 0
        hoverEdge?.isHidden = !collapsed
        if !collapsed { hideFloatingSidebar() }
        applyTrafficLightState()
        updateResizerVisibility()
    }
}

extension SephrWindowController {
    /// The drag grip is only meaningful while the sidebar is in full
    /// mode — compact (52pt) is a fixed width by design, and collapsed
    /// (0) has no surface to grab. Hiding the view also stops it from
    /// claiming the resize cursor over a non-resizable edge.
    fileprivate func updateResizerVisibility() {
        let w = sidebarWidthConstraint.constant
        let resizable = w > SephrSidebarView.compactWidth
        resizer?.isHidden = !resizable
    }
}

// MARK: — Link peek (Shift + click)

extension SephrWindowController {

    /// Watches global input for the two gestures that drive the link peek:
    /// Shift+clicking a link (to summon a peek of it) and Esc (to dismiss
    /// one). A local monitor sees the events before the focused web view
    /// does, so swallowing the Shift+click stops Chromium from also
    /// navigating to the link.
    fileprivate func installLinkPeekMonitor() {
        guard linkPeekMonitor == nil else { return }
        linkPeekMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleLinkPeekEvent(event)
            }
        }
    }

    private func handleLinkPeekEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // Esc closes an open peek and swallows the key so it doesn't
            // also reach the page. Any other key passes through.
            if linkPeek != nil, event.keyCode == 53 {
                dismissLinkPeek()
                return nil
            }
            return event

        case .leftMouseDown:
            // Shift+click a link → open it as a floating peek instead of
            // navigating. Require Shift with no Cmd/Ctrl (those have their
            // own click conventions), no peek already up, and the pointer
            // genuinely over an http(s) link — Chromium's UpdateTargetURL
            // keeps `hoveredLinkURL` current as the cursor moves. Returning
            // nil swallows the click so the page neither navigates nor
            // moves the caret.
            let flags = event.modifierFlags
            guard linkPeek == nil,
                  flags.contains(.shift),
                  flags.intersection([.command, .control]).isEmpty,
                  let raw = SephrTabModel.shared.activeTab()?.hoveredLinkURL,
                  let url = URL(string: raw),
                  url.scheme == "http" || url.scheme == "https" else {
                return event
            }
            presentLinkPeek(urlString: raw)
            return nil

        default:
            return event
        }
    }

    private func presentLinkPeek(urlString: String) {
        guard linkPeek == nil else { return }
        let profileID = SephrSpaceManager.shared.currentSpace.profileID
        let overlay = SephrLinkPeekOverlay(urlString: urlString,
                                           profileID: profileID)
        overlay.frame = contentHostView.bounds
        overlay.autoresizingMask = [.width, .height]
        // Sits above the active web view (and the split, and the loading
        // shimmer) inside the rounded page host.
        contentHostView.addSubview(overlay)
        overlay.onClose = { [weak self] in self?.dismissLinkPeek() }
        overlay.onOpenAsTab = { [weak self] url in
            self?.promotePeekToTab(urlString: url)
        }
        overlay.onOpenInSplit = { [weak self] url in
            self?.promotePeekToSplit(urlString: url)
        }
        linkPeek = overlay
        overlay.animateIn()
    }

    private func dismissLinkPeek() {
        guard let overlay = linkPeek else { return }
        linkPeek = nil
        // The closure retains `overlay` through the fade; removing it from
        // the view tree then drops the last reference, so the peek's
        // CALWebView deallocs and tears down its WebContents.
        overlay.animateOut { overlay.removeFromSuperview() }
    }

    /// A page opened a window.open popup (OAuth/SSO sign-in). Show the
    /// adopted live web view in a peek over the page. Only the key window
    /// presents, so a popup raised from the active tab lands on the window
    /// the user is actually looking at.
    @objc private func onPresentPopupPeek(_ note: Notification) {
        guard window?.isKeyWindow ?? false,
              let popup = note.object as? CALWebView else { return }
        // Re-home into the peek surface; replace any existing peek.
        dismissLinkPeek()
        let overlay = SephrLinkPeekOverlay(adoptingPopup: popup)
        overlay.frame = contentHostView.bounds
        overlay.autoresizingMask = [.width, .height]
        contentHostView.addSubview(overlay)
        overlay.onClose = { [weak self] in self?.dismissLinkPeek() }
        // window.close() after the popup posts its result home → dismiss.
        popup.onCloseRequest = { [weak self] in self?.dismissLinkPeek() }
        linkPeek = overlay
        overlay.animateIn()
    }

    /// Expand control — promote the peeked link into a real tab in the
    /// current space and show it. We open a fresh tab at the same URL
    /// rather than re-homing the peek's WebContents (CAL doesn't expose
    /// adopting an existing WebContents into a SephrTab).
    private func promotePeekToTab(urlString: String) {
        let space = SephrSpaceManager.shared.currentSpace
        let tab = SephrTabModel.shared.newTab(in: space, url: urlString)
        showTab(tab)
        dismissLinkPeek()
    }

    /// Split control — open the peeked link beside the current tab. Falls
    /// back to a plain tab if there's no active tab to anchor the split.
    private func promotePeekToSplit(urlString: String) {
        let space = SephrSpaceManager.shared.currentSpace
        guard let primary = SephrTabModel.shared.activeTab() else {
            promotePeekToTab(urlString: urlString)
            return
        }
        let secondary = SephrTabModel.shared.newTab(in: space, url: urlString)
        showSplit(primary: primary, secondary: secondary)
        dismissLinkPeek()
    }
}
