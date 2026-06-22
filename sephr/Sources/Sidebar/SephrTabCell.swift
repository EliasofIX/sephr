import AppKit
import SephrKit

protocol SephrTabCellDelegate: AnyObject {
    func tabCellDidSelect(_ cell: SephrTabCell)
    func tabCellDidClose(_ cell: SephrTabCell)
    func tabCellDidPin(_ cell: SephrTabCell)
    func tabCellDidDuplicate(_ cell: SephrTabCell)
    func tabCellDidCloseOthers(_ cell: SephrTabCell)
    func tabCellDidCloseToRight(_ cell: SephrTabCell)
}

final class SephrTabCell: NSView {

    /// EXPERIMENT — render the tab pill as an NSGlassEffectView (Liquid
    /// Glass) sitting behind the cell's content. Flip to `false` to
    /// revert to the previous white-tinted-layer pill in a single edit;
    /// both code paths live in `refreshAppearance()` below.
    private static let useGlassPill = true

    // Shared SF Symbol images — these were allocated every refresh
    // (favicon/audio glyph), once per tab × audio event. Cache once at
    // class load so the per-event refresh path is a property assignment
    // instead of an NSImage(systemSymbolName:) call. The audio button's
    // symbolConfiguration on the *button* binds these to the right point
    // size + weight, so cached images need no per-cell configuration.
    private static let noteGlyph = NSImage(
        systemSymbolName: "pencil.and.outline",
        accessibilityDescription: "Note")
    private static let globeGlyph = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: nil)
    private static let speakerPlayingGlyph = NSImage(
        systemSymbolName: "speaker.wave.2.fill",
        accessibilityDescription: "Playing audio — click to mute")
    private static let speakerMutedGlyph = NSImage(
        systemSymbolName: "speaker.slash.fill",
        accessibilityDescription: "Muted — click to unmute")
    private static let closeGlyph = NSImage(
        systemSymbolName: "xmark",
        accessibilityDescription: nil)

    let tab: SephrTab
    weak var delegate: SephrTabCellDelegate?

    private let favicon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = SephrHoverButton()
    /// Speaker badge between favicon and title — shown only while the tab is
    /// emitting audio (or is muted). Click toggles the tab's mute. Arc-style.
    private let audioButton = SephrHoverButton()
    /// The title's leading constraint has two forms — pinned to the favicon
    /// when there's no audio badge, pinned to the audio badge when it shows.
    /// Exactly one is active at a time (see `refreshAudioIndicator`).
    private var titleAfterFavicon: NSLayoutConstraint!
    private var titleAfterAudio: NSLayoutConstraint!
    /// Optional glass surface — only created when `useGlassPill` is on.
    /// Held as NSView so we don't have to drag the NSGlassEffectView
    /// availability check through the property type.
    private var glassPill: NSView?
    private var hoverTimer: Timer?
    private var peekPopover: SephrPeekPopover?
    private var compact = false
    private var hovered = false
    /// Per-tab event subscription — dropping the token unsubscribes,
    /// so it lives for the cell's lifetime.
    private var eventToken: TabEventToken?

    init(tab: SephrTab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard

        installGlassPillIfEnabled()
        refreshAppearance()

        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.translatesAutoresizingMaskIntoConstraints = false
        refreshFavicon()

        eventToken = TabEventBus.shared.subscribe(tabID: tab.id) { [weak self] event in
            self?.onTabEvent(event)
        }

        titleLabel.stringValue = tab.title.isEmpty ? tab.url : tab.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = Self.closeGlyph
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.contentTintColor = NSColor.secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.alphaValue = 0

        audioButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        audioButton.contentTintColor = NSColor.secondaryLabelColor
        audioButton.target = self
        audioButton.action = #selector(toggleMute)
        audioButton.isHidden = true

        [favicon, audioButton, titleLabel, closeButton].forEach { addSubview($0) }

        titleAfterFavicon = titleLabel.leadingAnchor.constraint(
            equalTo: favicon.trailingAnchor, constant: 8)
        titleAfterAudio = titleLabel.leadingAnchor.constraint(
            equalTo: audioButton.trailingAnchor, constant: 6)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 14),
            favicon.heightAnchor.constraint(equalToConstant: 14),

            audioButton.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor, constant: 6),
            audioButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            audioButton.widthAnchor.constraint(equalToConstant: 15),
            audioButton.heightAnchor.constraint(equalToConstant: 15),

            titleAfterFavicon,
            titleLabel.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        refreshAudioIndicator()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Appearance

    func setCompact(_ compact: Bool) {
        self.compact = compact
        titleLabel.isHidden = compact
        closeButton.isHidden = compact
        refreshAudioIndicator()  // badge sits in the (now-hidden) title run
        refreshAppearance()
    }

    /// Shows the speaker badge while the tab is emitting audio or is muted,
    /// and picks the glyph — a wave while playing, a slash while muted.
    /// Hidden otherwise, and in compact/icon-only mode. Flips the title's
    /// leading constraint so the title reflows to make room for the badge.
    private func refreshAudioIndicator() {
        let show = (tab.isAudible || tab.isAudioMuted) && !compact
        if audioButton.isHidden != !show { audioButton.isHidden = !show }
        // Deactivate both before activating one so the two leading
        // constraints never both bind `titleLabel` at once.
        let wantAudio = show ? titleAfterAudio : titleAfterFavicon
        let dropAudio = show ? titleAfterFavicon : titleAfterAudio
        if wantAudio?.isActive == false || dropAudio?.isActive == true {
            NSLayoutConstraint.deactivate([titleAfterFavicon, titleAfterAudio])
            NSLayoutConstraint.activate([wantAudio!])
        }
        guard show else { return }
        let muted = tab.isAudioMuted
        let wanted = muted ? Self.speakerMutedGlyph : Self.speakerPlayingGlyph
        if audioButton.image !== wanted { audioButton.image = wanted }
        let tint: NSColor = muted ? .tertiaryLabelColor : .labelColor
        if audioButton.contentTintColor !== tint { audioButton.contentTintColor = tint }
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
            g.cornerRadius = DC.Radius.standard
            g.tintColor = nil
            surface = g
        } else {
            let v = NSVisualEffectView(frame: .zero)
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = DC.Radius.standard
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
        // Notes have no page, so no favicon — a fixed canvas glyph
        // distinguishes them from web tabs at a glance (Arc-easel style).
        if tab.kind == .note {
            if favicon.image !== Self.noteGlyph { favicon.image = Self.noteGlyph }
            if favicon.contentTintColor !== NSColor.secondaryLabelColor {
                favicon.contentTintColor = .secondaryLabelColor
            }
            return
        }
        if let img = tab.favicon {
            if favicon.image !== img { favicon.image = img }
            if favicon.contentTintColor != nil { favicon.contentTintColor = nil }
        } else {
            if favicon.image !== Self.globeGlyph { favicon.image = Self.globeGlyph }
            if favicon.contentTintColor !== NSColor.secondaryLabelColor {
                favicon.contentTintColor = .secondaryLabelColor
            }
        }
    }

    private func onTabEvent(_ event: TabEvent) {
        switch event.kind {
        case .active:
            // The active-tab pill must track selection. `activateTab`
            // flips `isActive` on the (reference-type) tabs in the
            // model's array, which doesn't republish the @Published
            // array, so the sidebar never rebuilds these cells on a
            // plain tab switch. Both sides of a switch get their own
            // `.active` post, so refreshing here keeps the highlight
            // in step on this cell whether it gained or lost focus.
            refreshAppearance()
        case .favicon:
            refreshFavicon()
        case .title, .url:
            let newTitle = tab.title.isEmpty ? tab.url : tab.title
            if titleLabel.stringValue != newTitle {
                titleLabel.stringValue = newTitle
            }
        case .loading:
            break  // .loading: no cell-level UI; loading indicator lives in SephrWindowController
        case .audio:
            refreshAudioIndicator()
        case .media:
            break  // media session UI lives in the sidebar's Now Playing pill
        }
    }

    // MARK: — Events

    @objc private func close() { delegate?.tabCellDidClose(self) }

    /// Speaker-badge click → flip the tab's mute. The badge stays put (the
    /// tab is still audible); `toggleMute` posts a `.audio` event that
    /// repaints the glyph via `refreshAudioIndicator`.
    @objc private func toggleMute() { tab.toggleMute() }

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
        // `cacheDisplay(in:to:)` is the documented modern equivalent of
        // `lockFocus` + `layer.render` — it walks the view hierarchy and
        // rasterizes through Core Animation properly (so subviews like
        // the favicon image view show up at their correct sublayer
        // position, which the old layer.render path occasionally clipped
        // off when the cell was offscreen at install time).
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let reload = NSMenuItem(title: "Reload",
                                action: #selector(menuReload),
                                keyEquivalent: "")
        reload.target = self
        reload.isEnabled = tab.kind == .web
        menu.addItem(reload)

        let dup = NSMenuItem(title: "Duplicate",
                             action: #selector(menuDuplicate),
                             keyEquivalent: "")
        dup.target = self
        menu.addItem(dup)

        let pin = NSMenuItem(title: tab.isPinned ? "Unpin" : "Pin Tab",
                             action: #selector(menuPin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        // Mute / Unmute — only meaningful when the tab can play media.
        let mute = NSMenuItem(
            title: tab.isAudioMuted ? "Unmute" : "Mute Tab",
            action: #selector(menuToggleMute), keyEquivalent: "")
        mute.target = self
        mute.isEnabled = tab.isAudible || tab.isAudioMuted || tab.isMediaControllable
        menu.addItem(mute)

        menu.addItem(NSMenuItem.separator())

        let liveURL = (tab.webView?.currentURL ?? "") as String
        let resolvedURL = liveURL.isEmpty ? tab.url : liveURL
        if !resolvedURL.isEmpty {
            let copyURL = NSMenuItem(title: "Copy URL",
                                     action: #selector(menuCopyURL),
                                     keyEquivalent: "")
            copyURL.target = self
            menu.addItem(copyURL)
        }

        menu.addItem(NSMenuItem.separator())

        let close = NSMenuItem(title: "Close Tab",
                               action: #selector(menuClose),
                               keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        let closeOthers = NSMenuItem(title: "Close Other Tabs",
                                     action: #selector(menuCloseOthers),
                                     keyEquivalent: "")
        closeOthers.target = self
        menu.addItem(closeOthers)

        let closeRight = NSMenuItem(title: "Close Tabs Below",
                                    action: #selector(menuCloseToRight),
                                    keyEquivalent: "")
        closeRight.target = self
        menu.addItem(closeRight)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func menuReload() { tab.webView?.reload() }
    @objc private func menuDuplicate() { delegate?.tabCellDidDuplicate(self) }
    @objc private func menuPin() { delegate?.tabCellDidPin(self) }
    @objc private func menuToggleMute() { tab.toggleMute() }
    @objc private func menuClose() { delegate?.tabCellDidClose(self) }
    @objc private func menuCloseOthers() { delegate?.tabCellDidCloseOthers(self) }
    @objc private func menuCloseToRight() { delegate?.tabCellDidCloseToRight(self) }
    @objc private func menuCopyURL() {
        let live = (tab.webView?.currentURL ?? "") as String
        let url = live.isEmpty ? tab.url : live
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: — Hover → Peek

    /// Clears a stale hover left behind when the tab list scrolls under a
    /// stationary pointer — AppKit fires `mouseEntered` as rows pass under
    /// the cursor but not always `mouseExited` when they scroll away.
    func clearHoverState() {
        setHovered(false)
    }

    /// Reconcile hover with the current pointer after a scroll. Skips peek
    /// popovers — those should only arm from a real `mouseEntered`.
    func syncHoverUnderPointer(allowPeek: Bool = false) {
        guard let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(local), allowPeek: allowPeek)
    }

    private func setHovered(_ hovered: Bool, allowPeek: Bool = true) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
        refreshAppearance()
        if hovered {
            closeButton.animator().alphaValue = 1
            guard allowPeek, SephrPreferences.peekOnSidebarHover else { return }
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3,
                                               repeats: false) { [weak self] _ in
                guard let self else { return }
                let popover = SephrPeekPopover(tab: self.tab)
                popover.show(relativeTo: self.bounds, of: self,
                              preferredEdge: .maxX)
                self.peekPopover = popover
            }
        } else {
            closeButton.animator().alphaValue = 0
            hoverTimer?.invalidate()
            hoverTimer = nil
            peekPopover?.close()
            peekPopover = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.inVisibleRect` makes AppKit rebuild the tracking area against
        // the cell's current visible bounds itself, instead of capturing
        // a frozen rect that drifts the instant the sidebar scrolls. The
        // previous `rect: bounds` version stale-cached the rect at install
        // time, so a fast scroll could leave the cell silently un-hoverable
        // until the next layout pass.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited,
                       .activeInKeyWindow,
                       .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
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
