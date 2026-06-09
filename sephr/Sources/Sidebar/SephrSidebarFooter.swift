import AppKit
import SwiftUI

final class SephrSidebarFooter: NSView {
    var onCreateSpace:  (() -> Void)?
    var onCreateFolder: (() -> Void)?
    var onCreateTab:    (() -> Void)?
    var onSelectSpace:  ((SephrSpace) -> Void)?

    private let plusButton = SephrHoverButton()
    private let downloadsButton = SephrDownloadsButton()
    private let spaceSwitcher = SephrSpaceSwitcherFooter()
    private var downloadsPopover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        plusButton.image = NSImage(systemSymbolName: "plus",
                                   accessibilityDescription: nil)
        plusButton.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        plusButton.contentTintColor = NSColor.secondaryLabelColor
        plusButton.target = self
        plusButton.action = #selector(showCreateMenu)
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
            plusButton.widthAnchor.constraint(equalToConstant: 26),
            plusButton.heightAnchor.constraint(equalToConstant: 26),

            // Downloads on the bottom-left, same row as the "+".
            downloadsButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 14),
            downloadsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadsButton.widthAnchor.constraint(equalToConstant: 26),
            downloadsButton.heightAnchor.constraint(equalToConstant: 26),

            // Space switcher fills the middle, between downloads and
            // the "+". Centered on its own to keep the active space
            // visually grounded regardless of how many spaces there are.
            spaceSwitcher.leadingAnchor.constraint(
                equalTo: downloadsButton.trailingAnchor, constant: 6),
            spaceSwitcher.trailingAnchor.constraint(
                equalTo: plusButton.leadingAnchor, constant: -6),
            spaceSwitcher.centerYAnchor.constraint(equalTo: centerYAnchor),
            spaceSwitcher.heightAnchor.constraint(equalToConstant: 28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showCreateMenu() {
        let menu = NSMenu()

        let tab = NSMenuItem(title: "New Tab",
                             action: #selector(menuNewTab),
                             keyEquivalent: "t")
        tab.target = self

        let folder = NSMenuItem(title: "New Folder",
                                action: #selector(menuNewFolder),
                                keyEquivalent: "")
        folder.target = self

        let space = NSMenuItem(title: "New Space",
                               action: #selector(menuNewSpace),
                               keyEquivalent: "")
        space.target = self

        menu.addItem(tab)
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
        let host = NSHostingController(rootView: SephrDownloadsPanel())
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        popover.contentViewController = host
        popover.show(relativeTo: downloadsButton.bounds,
                     of: downloadsButton,
                     preferredEdge: .maxY)
        downloadsPopover = popover
    }
}
