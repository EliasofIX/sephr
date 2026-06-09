import AppKit
import SwiftUI
import CAL
import SephrKit

/// Inline URL input inside the sidebar (Zen-style — no horizontal
/// titlebar). Submits to the active SephrTab or opens a new tab when
/// the user hits Enter.
final class SephrSidebarURLField: NSView, NSTextFieldDelegate, NSPopoverDelegate {

    private let field = NSTextField()
    private var lastSyncedTabID: UUID?

    /// Bus subscriptions. `structureToken` lives for the field's
    /// lifetime; `activeTabToken` is swapped every time the active-tab
    /// identity moves (see `resubscribeToActiveTab`). Dropping a token
    /// unsubscribes.
    private var structureToken: TabEventToken?
    private var activeTabToken: TabEventToken?
    private var lastSubscribedTabID: UUID?

    /// Trailing action buttons that fade in over the pill while the
    /// sidebar is hovered: copy-link and the page-settings popover.
    private let copyButton = SephrSidebarActionButton(symbols: ["link"])
    private let settingsButton = SephrSidebarActionButton(
        symbols: ["slider.horizontal.2.square", "switch.2",
                  "slider.horizontal.3"])
    private let actionCluster = NSStackView()
    private var settingsPopover: NSPopover?
    private var actionsVisible = false

    /// True while the page-settings popover is on screen — the sidebar's
    /// hover tracking checks this so the action buttons don't fade out
    /// from under an open panel.
    var isSettingsPanelOpen: Bool { settingsPopover?.isShown ?? false }

    /// Fired when the page-settings popover closes, so the host sidebar
    /// can re-evaluate whether the action buttons should stay visible.
    var onSettingsPanelClosed: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // macOS 26 Liquid Glass pill behind the text field. The pill is
        // sized to the URL field's bounds and uses a half-height corner
        // radius so it reads as a capsule. Falls back to a tinted vibrancy
        // view on older systems so the field still has visible chrome.
        let pill: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: .zero)
            g.cornerRadius = 15  // half of the field's 30pt height
            g.tintColor = nil
            pill = g
        } else {
            let v = NSVisualEffectView(frame: .zero)
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 15
            v.layer?.masksToBounds = true
            pill = v
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        field.placeholderString = "Search or enter URL"
        field.font = .systemFont(ofSize: 13)
        // Left-aligned so the host reads from the leading edge (Dia-style),
        // truncating the tail of long URLs rather than the head.
        field.alignment = .left
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        addSubview(field)

        // Trailing action cluster — hidden at rest, revealed on sidebar
        // hover. Lives on top of the pill at the field's right edge.
        copyButton.target = self
        copyButton.action = #selector(copyLink)
        copyButton.toolTip = "Copy link"
        settingsButton.target = self
        settingsButton.action = #selector(toggleSettingsPanel)
        settingsButton.toolTip = "Page settings"

        actionCluster.orientation = .horizontal
        actionCluster.spacing = 2
        actionCluster.translatesAutoresizingMaskIntoConstraints = false
        actionCluster.addArrangedSubview(copyButton)
        actionCluster.addArrangedSubview(settingsButton)
        actionCluster.alphaValue = 0
        actionCluster.isHidden = true
        addSubview(actionCluster)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 12),
            // Stop the text short of the action cluster so the URL never
            // runs underneath the buttons — the layout stays stable
            // whether or not the cluster is currently faded in.
            field.trailingAnchor.constraint(
                equalTo: actionCluster.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionCluster.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -8),
            actionCluster.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Sync the field text to the active tab's URL whenever the
        // model changes (but don't stomp text mid-edit). Structure
        // events (tab created / closed / moved) can change which tab
        // is active, so re-anchor the per-tab subscription too.
        structureToken = TabEventBus.shared.subscribeStructure { [weak self] in
            self?.resubscribeToActiveTab()
            self?.syncURL()
        }
        resubscribeToActiveTab()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// (Re-)subscribe to the CURRENT active tab so its `.url` updates
    /// reach the field. Plain tab switches don't post structure events,
    /// only per-tab `.active` to both sides — the OLD tab's `.active`
    /// arrives on our current subscription, and the handler re-anchors
    /// to the new active tab from there (activateTab flips the new tab
    /// on before posting the old tab's deactivation, so `activeTab()`
    /// already resolves to the new one when we land here).
    private func resubscribeToActiveTab() {
        let active = SephrTabModel.shared.activeTab()
        guard active?.id != lastSubscribedTabID else { return }
        lastSubscribedTabID = active?.id
        activeTabToken = nil
        if let active {
            activeTabToken = TabEventBus.shared.subscribe(tabID: active.id) {
                [weak self] event in
                if event.kind == .active {
                    self?.resubscribeToActiveTab()
                }
                if event.kind == .url || event.kind == .active {
                    self?.syncURL()
                }
            }
        }
        syncURL()
    }

    func makeFirstResponder() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func syncURL() {
        let active = SephrTabModel.shared.activeTab()
        // Prefer the web view's live committed URL (GetLastCommittedURL,
        // always canonical) over the cached `tab.url`. The cache is updated
        // only by the onNavigation callback, which is wired a beat after
        // the initial load is kicked off in the bridge — so the first
        // commit (and server-side redirects) can be missed, leaving the
        // bar blank or showing the pre-redirect URL. The live read makes
        // the bar reflect the page you're actually on.
        let live = active?.webView?.currentURL
        let cur = (live?.isEmpty == false ? live : active?.url) ?? ""
        let activeID = active?.id
        // If the active tab changed (user clicked a different tab), force the
        // field to reflect it — even mid-edit. The user's typing belonged to
        // the previously-active tab; once they switch, that context is gone.
        let tabSwitched = activeID != lastSyncedTabID
        let editing = window?.firstResponder == field.currentEditor()
        guard tabSwitched || !editing else { return }
        if editing && tabSwitched {
            window?.makeFirstResponder(nil)
        }
        if field.stringValue != cur {
            field.stringValue = cur
        }
        lastSyncedTabID = activeID
    }

    @objc private func submit() {
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let resolved = Self.resolveAsURL(s)
            ?? SephrSearchEngines.queryURL(for: s)
            ?? s
        let space = SephrSpaceManager.shared.currentSpace
        if let active = SephrTabModel.shared.activeTab(),
           active.spaceID == space.id {
            active.webView?.loadURL(resolved)
            active.url = resolved
        } else {
            _ = SephrTabModel.shared.newTab(in: space, url: resolved)
        }
        // Drop focus so the text deselects and subsequent navigation
        // notifications can update the field's contents.
        window?.makeFirstResponder(nil)
    }

    /// Heuristic: if the input has no spaces and looks like a URL (has
    /// scheme, "localhost", or contains a dot), treat it as a URL.
    /// Anything else gets routed through DuckDuckGo search.
    private static func resolveAsURL(_ s: String) -> String? {
        if s.contains(" ") { return nil }
        if s.hasPrefix("sephr://") || s.hasPrefix("file://") { return s }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("localhost") || s.contains(".") {
            return "https://" + s
        }
        return nil
    }

    // MARK: — Hover action buttons

    /// Fade the trailing copy / settings buttons in or out. Toggling
    /// `isHidden` around the animation keeps a faded-out cluster from
    /// swallowing clicks meant for the pill underneath.
    func setActionsVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != actionsVisible else { return }
        actionsVisible = visible
        if visible { actionCluster.isHidden = false }
        guard animated else {
            actionCluster.alphaValue = visible ? 1 : 0
            actionCluster.isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            actionCluster.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.actionCluster.isHidden = true }
        })
    }

    /// The page URL the action buttons operate on — the active tab's
    /// live committed URL, falling back to its cached URL.
    private func currentURLString() -> String {
        let active = SephrTabModel.shared.activeTab()
        let live = active?.webView?.currentURL
        return (live?.isEmpty == false ? live : active?.url) ?? ""
    }

    @objc private func copyLink() {
        let url = currentURLString()
        guard !url.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        flashCopied()
    }

    /// Swap the copy glyph to a checkmark for a beat as confirmation.
    private func flashCopied() {
        copyButton.setSymbol("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.setSymbol("link")
        }
    }

    @objc private func toggleSettingsPanel() {
        if let existing = settingsPopover, existing.isShown {
            existing.close()
            return
        }
        let profileID = MainActor.assumeIsolated {
            SephrSpaceManager.shared.currentSpace.profileID
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        let panel = SephrPageSettingsPanel(
            url: currentURLString(),
            profileID: profileID,
            onScreenshot: { [weak self] in self?.captureScreenshot() },
            onDevTools: { [weak self] in self?.openDevTools() },
            onOpenSettings: { [weak self] in self?.openFullSettings() })
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = .preferredContentSize
        host.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = host

        popover.show(relativeTo: settingsButton.bounds,
                     of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    private func captureScreenshot() {
        guard let webView = SephrTabModel.shared.activeTab()?.webView else { return }
        // Capture at native pixel size so the result is crisp on Retina
        // rather than the half-resolution point-sized thumbnail default.
        let scale = webView.window?.backingScaleFactor ?? 2.0
        let bounds = webView.bounds.size
        let size = NSSize(width: bounds.width * scale,
                          height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return }
        webView.captureThumb(with: size) { image in
            guard let image else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
    }

    private func openDevTools() {
        SephrTabModel.shared.activeTab()?.webView?.openDevTools()
    }

    private func openFullSettings() {
        settingsPopover?.close()
        MainActor.assumeIsolated {
            SephrSettingsController.shared.showSettings(nil)
        }
    }

    // MARK: — NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        settingsPopover = nil
        onSettingsPanelClosed?()
    }
}

/// Trailing URL-bar action button (copy-link / page-settings). Subtle
/// hover tint from `SephrHoverButton`; takes a fallback list of SF Symbol
/// names so it degrades gracefully when a glyph is missing on older
/// macOS.
final class SephrSidebarActionButton: SephrHoverButton {
    init(symbols: [String]) {
        super.init(frame: .zero)
        for name in symbols {
            if let img = NSImage(systemSymbolName: name,
                                 accessibilityDescription: nil) {
                image = img
                break
            }
        }
        symbolConfiguration = .init(pointSize: 12, weight: .medium)
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Swap the glyph at runtime (used for the copy-confirmation flash).
    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

/// Back / Forward / Reload trio that sits in a horizontal strip above the
/// URL field in the sidebar.
final class SephrSidebarNavStrip: NSView {
    private let back    = SephrSidebarNavButton(symbol: "chevron.backward")
    private let forward = SephrSidebarNavButton(symbol: "chevron.forward")
    private let reload  = SephrSidebarNavButton(symbol: "arrow.clockwise")

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.target = self;    back.action    = #selector(doBack)
        forward.target = self; forward.action = #selector(doForward)
        reload.target = self;  reload.action  = #selector(doReload)

        let row = NSStackView(views: [back, forward, reload])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func doBack()    { SephrTabModel.shared.activeTab()?.webView?.goBack() }
    @objc private func doForward() { SephrTabModel.shared.activeTab()?.webView?.goForward() }
    @objc private func doReload()  { SephrTabModel.shared.activeTab()?.webView?.reload() }
}

final class SephrSidebarNavButton: SephrHoverButton {
    init(symbol: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 12, weight: .medium)
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}
