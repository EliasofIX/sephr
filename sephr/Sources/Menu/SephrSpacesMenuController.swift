import AppKit

/// Installs and maintains a top-level "Spaces" menu in the macOS menu
/// bar. Chromium's AppController owns `NSApp.mainMenu` and re-templates
/// it on activation / profile load, so `install()` is idempotent — it
/// finds our item by tag instead of inserting duplicates — and is
/// re-asserted from SephrApp's boot callback, after a beat, and on every
/// app activation. This mirrors the triple-assert pattern that
/// `SephrSettingsController` / `SephrQuitController` use.
///
/// The submenu is rebuilt lazily in `menuNeedsUpdate(_:)` each time the
/// user opens it, so the live space list and the current-space checkmark
/// stay correct without any notification bookkeeping.
@MainActor
final class SephrSpacesMenuController: NSObject, NSMenuDelegate {

    static let shared = SephrSpacesMenuController()

    /// Marks our top-level item so `install()` can find + reuse it rather
    /// than inserting a fresh "Spaces" menu each time Chromium rebuilds
    /// the bar. ('SPCS')
    private static let menuTag = 0x53504353

    private let spacesMenu = NSMenu(title: "Spaces")

    private var verbose = ProcessInfo.processInfo.environment["SEPHR_MENU_DEBUG"] != nil

    private override init() {
        super.init()
        spacesMenu.delegate = self
        spacesMenu.autoenablesItems = false
        // Self-heal on the precise moments Chromium rebuilds the menu bar
        // (profile load, full-screen, AppKit nib load) instead of a 1Hz
        // forever-Timer chewing the run loop. didBecomeActive covers any
        // case the boot-time install missed; menuDidBeginTracking handles
        // a rebuild that landed mid-session before the user clicked.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SephrSpacesMenuController.shared.install() }
        }
    }

    /// Inserts the Spaces menu into the main menu bar if it isn't there
    /// already. Safe to call repeatedly — it's a no-op when our item is
    /// already present.
    func install() {
        guard let mainMenu = NSApp.mainMenu else {
            slog("install: NSApp.mainMenu is nil")
            return
        }
        if mainMenu.items.contains(where: { $0.tag == Self.menuTag }) { return }

        let item = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
        item.tag = Self.menuTag
        item.submenu = spacesMenu
        rebuild(spacesMenu)   // populate once so it isn't empty pre-open
        let idx = insertionIndex(in: mainMenu)
        mainMenu.insertItem(item, at: idx)
        slog("inserted at \(idx); top-level now: " +
             mainMenu.items.map { "\"\($0.title)\"" }.joined(separator: ","))
    }

    /// Slot the Spaces menu just before "Window" (falling back to before
    /// "Help", else the end). Top-level NSMenuItems often carry an empty
    /// `title` (the visible label lives on their `submenu.title`), so we
    /// match against both.
    private func insertionIndex(in menu: NSMenu) -> Int {
        func matches(_ item: NSMenuItem, _ name: String) -> Bool {
            item.title == name || item.submenu?.title == name
        }
        if let w = menu.items.firstIndex(where: { matches($0, "Window") }) {
            return w
        }
        if let h = menu.items.firstIndex(where: { matches($0, "Help") }) {
            return h
        }
        return menu.items.count
    }

    private func slog(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("[spaces-menu] \(message)\n".utf8))
    }

    // MARK: — NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: — Build

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let newItem = NSMenuItem(title: "New Space…",
                                 action: #selector(newSpace),
                                 keyEquivalent: "s")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        let rename = NSMenuItem(title: "Rename Space",
                                action: #selector(renameSpace),
                                keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        menu.addItem(.separator())

        // ⌥⌘→ / ⌥⌘← — set as display key equivalents. The actual key
        // presses are caught upstream by SephrKeyboardShortcutMonitor so
        // they reliably win over any Chromium "Select Next/Previous Tab"
        // accelerator bound to the same chord; the glyphs here are just
        // for the menu's affordance.
        let next = NSMenuItem(title: "Next Space",
                              action: #selector(nextSpace),
                              keyEquivalent: Self.rightArrow)
        next.keyEquivalentModifierMask = [.command, .option]
        next.target = self
        menu.addItem(next)

        let prev = NSMenuItem(title: "Previous Space",
                              action: #selector(previousSpace),
                              keyEquivalent: Self.leftArrow)
        prev.keyEquivalentModifierMask = [.command, .option]
        prev.target = self
        menu.addItem(prev)

        menu.addItem(.separator())

        let mgr = SephrSpaceManager.shared
        for (i, space) in mgr.spaces.enumerated() {
            // ^1…^9 (Control+number) for the first nine spaces. Distinct
            // from the existing Cmd+1…9 binding in the keyboard monitor,
            // which stays live.
            let key = i < 9 ? String(i + 1) : ""
            let item = NSMenuItem(title: space.name,
                                  action: #selector(switchToSpace(_:)),
                                  keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = .control }
            item.target = self
            item.representedObject = space.id.uuidString
            item.state = (space.id == mgr.currentSpace.id) ? .on : .off
            item.image = icon(for: space)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let footerLabel = NSMenuItem(
            title: "Sidebar Footer (4 max)",
            action: nil, keyEquivalent: "")
        footerLabel.isEnabled = false
        menu.addItem(footerLabel)

        for space in mgr.spaces {
            let fav = NSMenuItem(
                title: space.name,
                action: #selector(toggleFavoriteSpace(_:)),
                keyEquivalent: "")
            fav.target = self
            fav.representedObject = space.id.uuidString
            fav.state = space.isFavorited ? .on : .off
            fav.image = icon(for: space)
            menu.addItem(fav)
        }

        menu.addItem(.separator())

        let manage = NSMenuItem(title: "Manage Spaces…",
                                action: #selector(manageSpaces),
                                keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    /// A small SF-symbol image tinted with the space's accent color, so
    /// each row in the menu carries its space's identity. Cached on
    /// `(spaceID, symbol, colorHex)` so reopening the menu doesn't
    /// re-allocate every row's NSImage just because the user clicked it.
    private struct IconCacheKey: Hashable {
        let id: UUID; let symbol: String; let colorHex: String
    }
    private var iconCache: [IconCacheKey: NSImage] = [:]

    private func icon(for space: SephrSpace) -> NSImage? {
        let key = IconCacheKey(id: space.id,
                                symbol: space.resolvedSymbol,
                                colorHex: space.color.hexString)
        if let cached = iconCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [space.color]))
        let img = NSImage(systemSymbolName: space.resolvedSymbol,
                          accessibilityDescription: space.name)?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        if let img { iconCache[key] = img }
        // Bound the cache against long sessions where the user rotates
        // through many spaces/colors; 64 covers every realistic combo.
        if iconCache.count > 64 {
            iconCache.removeAll(keepingCapacity: true)
        }
        return img
    }

    // MARK: — Actions

    @objc private func newSpace() {
        guard let wc = SephrApp.mainController else { return }
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.sidebarView?.showCreateSpace()
    }

    @objc private func renameSpace() {
        var space = SephrSpaceManager.shared.currentSpace
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        alert.informativeText = "Enter a new name for “\(space.name)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = space.name
        field.placeholderString = "Space name…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        space.name = name
        SephrSpaceManager.shared.updateSpace(space)
    }

    @objc private func nextSpace() {
        SephrSpaceManager.shared.switchByOffset(1)
    }

    @objc private func previousSpace() {
        SephrSpaceManager.shared.switchByOffset(-1)
    }

    @objc private func switchToSpace(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let space = SephrSpaceManager.shared.spaces
                .first(where: { $0.id == id }) else { return }
        SephrSpaceManager.shared.switchToSpace(space)
    }

    @objc private func toggleFavoriteSpace(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let space = SephrSpaceManager.shared.spaces
                .first(where: { $0.id == id }) else { return }
        SephrSpaceManager.shared.toggleFavorite(space)
    }

    @objc private func manageSpaces() {
        SephrManageSpacesController.shared.show()
    }

    // MARK: — Arrow key equivalents

    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    private static let leftArrow  = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
}
