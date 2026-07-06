import AppKit
import SwiftUI

/// Shared hit-target + glyph box for the footer row so the downloads
/// chip, space pips, and "+" read as one aligned toolbar.
enum SephrSidebarFooterMetrics {
    static let controlSize: CGFloat = 28
    /// Every SF Symbol scales into this box so thin glyphs ("+") and
    /// airy ones ("circle.hexagongrid") match the filled circle download
    /// icon in perceived height.
    static let iconBoxSize: CGFloat = 16
    /// Nudge glyphs up to leave room for the active-space pip dot.
    static let iconCenterYOffset: CGFloat = -3
    static let symbolPointSize: CGFloat = 12
}

final class SephrSidebarFooter: NSView {
    var onCreateSpace:  (() -> Void)?
    var onCreateFolder: (() -> Void)?
    var onCreateTab:    (() -> Void)?
    var onCreateNote:   (() -> Void)?
    var onSelectSpace:  ((SephrSpace) -> Void)?

    private let plusButton = SephrFooterPlusButton()
    private let downloadsButton = SephrDownloadsButton()
    private let spaceSwitcher = SephrSpaceSwitcherFooter()
    private var downloadsPopover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        plusButton.onClicked = { [weak self] in self?.showCreateMenu() }
        addSubview(plusButton)

        downloadsButton.onClicked = { [weak self] in
            self?.showDownloadsPopover()
        }
        addSubview(downloadsButton)

        spaceSwitcher.onSelect = { [weak self] s in self?.onSelectSpace?(s) }
        addSubview(spaceSwitcher)

        NSLayoutConstraint.activate([
            // Anchor the "+" to the bottom-right corner of the sidebar.
            plusButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -14),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),
            plusButton.heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),

            // Downloads on the bottom-left, same row as the "+".
            downloadsButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 14),
            downloadsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadsButton.widthAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),
            downloadsButton.heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),

            // Space switcher fills the middle, between downloads and
            // the "+". Centered on its own to keep the active space
            // visually grounded regardless of how many spaces there are.
            spaceSwitcher.leadingAnchor.constraint(
                equalTo: downloadsButton.trailingAnchor, constant: 6),
            spaceSwitcher.trailingAnchor.constraint(
                equalTo: plusButton.leadingAnchor, constant: -6),
            spaceSwitcher.centerYAnchor.constraint(equalTo: centerYAnchor),
            spaceSwitcher.heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.controlSize),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showCreateMenu() {
        let menu = NSMenu()

        let tab = NSMenuItem(title: "New Tab",
                             action: #selector(menuNewTab),
                             keyEquivalent: "t")
        tab.target = self

        let note = NSMenuItem(title: "New Note",
                              action: #selector(menuNewNote),
                              keyEquivalent: "")
        note.target = self

        let folder = NSMenuItem(title: "New Folder",
                                action: #selector(menuNewFolder),
                                keyEquivalent: "")
        folder.target = self

        let space = NSMenuItem(title: "New Space",
                               action: #selector(menuNewSpace),
                               keyEquivalent: "")
        space.target = self

        menu.addItem(tab)
        menu.addItem(note)
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(space)

        // Pop just below the plus button so the menu reads as attached
        // to it, like an Arc-style "+ ⌄" picker.
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: plusButton)
        } else {
            let origin = NSPoint(x: 0, y: plusButton.bounds.maxY + 4)
            menu.popUp(positioning: nil, at: origin, in: plusButton)
        }
    }

    @objc private func menuNewTab()    { onCreateTab?() }
    @objc private func menuNewNote()   { onCreateNote?() }
    @objc private func menuNewFolder() { onCreateFolder?() }
    @objc private func menuNewSpace()  { onCreateSpace?() }

    private func showDownloadsPopover() {
        if let existing = downloadsPopover, existing.isShown {
            existing.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = SephrFirstMouseHostingController(rootView: SephrDownloadsPanel())
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        popover.contentViewController = host
        popover.show(relativeTo: downloadsButton.bounds,
                     of: downloadsButton,
                     preferredEdge: .maxY)
        downloadsPopover = popover
    }
}

// MARK: — Footer "+"

private final class SephrFooterPlusButton: NSView {
    var onClicked: (() -> Void)?

    private let icon = NSImageView()
    private var hovered = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        toolTip = "New"

        SephrSidebarFooterMetrics.configureFooterIcon(
            icon, symbolName: "plus", accessibilityDescription: "New")
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: SephrSidebarFooterMetrics.iconCenterYOffset),
            icon.widthAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.iconBoxSize),
            icon.heightAnchor.constraint(
                equalToConstant: SephrSidebarFooterMetrics.iconBoxSize),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

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
        hovered = true
        refreshBackground()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshBackground()
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        refreshBackground()
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        refreshBackground()
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClicked?()
        }
    }

    private func refreshBackground() {
        let alpha: CGFloat = pressed ? 0.18 : (hovered ? 0.10 : 0.0)
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(alpha).cgColor
    }
}

extension SephrSidebarFooterMetrics {
    static func configureFooterIcon(
        _ imageView: NSImageView,
        symbolName: String,
        accessibilityDescription: String?
    ) {
        imageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription)
        imageView.symbolConfiguration = .init(
            pointSize: symbolPointSize, weight: .medium)
        imageView.contentTintColor = NSColor.secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
    }
}
