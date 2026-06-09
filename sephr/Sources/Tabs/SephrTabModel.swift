import AppKit
import Combine
import SephrKit

@MainActor
final class SephrTabModel: ObservableObject {
    static let shared = SephrTabModel()

    @Published private(set) var allTabs: [SephrTab] = []
    @Published private(set) var allFolders: [SephrTabFolder] = []

    private var archiveTimer: Timer?
    private var selectionAnchor: UUID?

    /// Pending coalesced-persist work. We get a `persist()` call after
    /// every tab activate, navigation, favicon arrival, etc. — at
    /// human-scale interaction rates that can easily be 5-10/sec while
    /// a SPA is loading. Each call previously did a synchronous JSON
    /// encode + disk write of the full session on the main thread.
    /// We coalesce into a single trailing write `persistDebounce`
    /// seconds out and flush eagerly on quit (see `flushPersist`).
    private var persistPending: DispatchWorkItem?
    private static let persistDebounce: TimeInterval = 0.25

    private init() {
        let session = SephrSessionStore.shared.loadSession()
        self.allTabs = session.tabs
        self.allFolders = session.folders
        rebindFolderReferences()
        scheduleAutoArchive()
    }

    // MARK: — Tab CRUD

    @discardableResult
    func newTab(in space: SephrSpace,
                url: String = "about:blank") -> SephrTab {
        // Default to about:blank — `sephr://newtab` isn't a registered
        // protocol on the Chromium side and LoadURLing it crashed the
        // renderer (DCHECK in NavigationControllerImpl). The visible
        // entry point is the search palette anyway: footer "+" opens
        // it and a tab is only created when the user picks a URL.
        let tab = SephrTab(url: url, title: "New Tab", spaceID: space.id)
        _ = tab.getOrCreateWebView()   // warm so the first paint is snappy
        allTabs.append(tab)
        activateTab(tab)
        emit(); persist()
        return tab
    }

    func closeTab(_ tab: SephrTab) {
        // Closing a split member dissolves the whole group — a half-empty
        // split pill would be meaningless.
        if SephrSplitManager.shared.contains(tab.id) {
            SephrSplitManager.shared.clear()
        }
        tab.webView?.removeFromSuperview()
        allTabs.removeAll { $0.id == tab.id }
        emit(); persist()
    }

    func closeActiveTab() {
        guard let tab = activeTab() else { return }
        closeTab(tab)
    }

    func activateTab(_ tab: SephrTab) {
        // Activate the target FIRST, then deactivate the others. The
        // old tab's `.active` post must observe a model where
        // `activeTab()` already resolves to the new tab — the URL
        // field re-anchors its per-tab subscription from exactly that
        // event. (The brief two-actives overlap during the target's
        // own post is harmless: the target's subscribers only read the
        // target's own flag.) Re-activation posts nothing — setActive
        // only fires on an actual flag change.
        tab.lastAccessedAt = Date()
        setActive(tab, to: true)
        for t in allTabs where t.id != tab.id {
            setActive(t, to: false)
        }
        // Persist so the "which tab was selected" state survives a
        // relaunch — otherwise the previously-active tab from the
        // saved session is the one that opens, not the one the user
        // last clicked.
        emit(); persist()
    }

    /// Single source of truth for `isActive` flips: changes the flag
    /// and posts `.active` — only on an actual change. The post is
    /// synchronous and subscribers read the model from their handlers,
    /// so call sites must not invoke this mid-mutation: complete the
    /// structural change first, then flip.
    private func setActive(_ tab: SephrTab, to flag: Bool) {
        guard tab.isActive != flag else { return }
        tab.isActive = flag
        TabEventBus.shared.post(TabEvent(tabID: tab.id, kind: .active))
    }

    func pinTab(_ tab: SephrTab, pinned: Bool) {
        tab.isPinned = pinned
        emit(); persist()
    }

    /// Pin `tab` (if it isn't already) AND position it at `newIndex` in the
    /// cross-space pinned list — the order `allPinnedTabs()` returns and the
    /// favorites row renders. Drives the favorites row's drag-and-drop: a
    /// regular tab dropped into the grid gets pinned at the drop slot, and a
    /// pinned chip dragged within the grid is re-slotted.
    ///
    /// Pinned order is just the relative order of pinned tabs inside the flat
    /// `allTabs` array, so re-slotting means physically moving the tab there.
    /// `newIndex` is an insertion index over the CURRENTLY VISIBLE pins
    /// (which include `tab` when it's already pinned) — we remove `tab`
    /// first, so when it started before the target the target shifts left
    /// by one. Without that correction a drag-to-the-right lands one slot
    /// short of where it was dropped.
    func movePinnedTab(_ tab: SephrTab, toIndex newIndex: Int) {
        let pinsBefore = allPinnedTabs()
        let originalIndex = pinsBefore.firstIndex { $0.id == tab.id }

        tab.isPinned = true
        tab.isArchived = false
        // A pin is cross-space and lives in the favorites grid, not inside
        // any space's folder — drop folder membership so it doesn't keep
        // rendering in a folder it was dragged out of.
        tab.folder = nil
        tab.folderID = nil

        guard let from = allTabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        allTabs.remove(at: from)

        var target = max(0, min(newIndex, pinsBefore.count))
        if let originalIndex, originalIndex < target { target -= 1 }

        // `pins` excludes `tab` now (removed above). Map the pinned-slot
        // target to an absolute index in `allTabs`.
        let pins = allTabs.filter { $0.isPinned && !$0.isArchived }
        target = max(0, min(target, pins.count))
        let insertAt: Int
        if pins.isEmpty {
            insertAt = 0
        } else if target >= pins.count {
            let lastID = pins[pins.count - 1].id
            insertAt = (allTabs.firstIndex { $0.id == lastID }
                        .map { $0 + 1 }) ?? allTabs.count
        } else {
            insertAt = allTabs.firstIndex { $0.id == pins[target].id }
                       ?? allTabs.count
        }
        allTabs.insert(tab, at: min(insertAt, allTabs.count))
        emit(); persist()
    }

    func activeTab() -> SephrTab? {
        allTabs.first { $0.isActive }
    }

    // MARK: — Sibling navigation

    func nextTab() {
        let space = SephrSpaceManager.shared.currentSpace
        let siblings = tabs(in: space)
        guard !siblings.isEmpty,
              let current = activeTab(),
              let idx = siblings.firstIndex(where: { $0.id == current.id })
        else { return }
        let next = siblings[(idx + 1) % siblings.count]
        activateTab(next)
    }

    func previousTab() {
        let space = SephrSpaceManager.shared.currentSpace
        let siblings = tabs(in: space)
        guard !siblings.isEmpty,
              let current = activeTab(),
              let idx = siblings.firstIndex(where: { $0.id == current.id })
        else { return }
        let prev = siblings[(idx - 1 + siblings.count) % siblings.count]
        activateTab(prev)
    }

    // MARK: — Folders

    /// Soft slate-blue used as the default folder tint. Sits quietly on
    /// the dark Liquid Glass sidebar — keeps a touch of identity without
    /// fighting the surrounding chrome the way the previous saturated
    /// space-accent did. Callers can still pass a stronger color when
    /// they explicitly want one.
    static let defaultFolderColor: NSColor =
        NSColor(hexString: "#9DACBA") ?? .secondaryLabelColor

    @discardableResult
    func createFolder(name: String,
                      color: NSColor? = nil,
                      symbolName: String = "folder.fill",
                      in space: SephrSpace) -> SephrTabFolder {
        // Resolved inside the method (MainActor context) so the
        // `defaultFolderColor` static doesn't get touched from a
        // nonisolated default-argument evaluation site.
        let resolved = color ?? Self.defaultFolderColor
        let f = SephrTabFolder(name: name, colorHex: resolved.hexString,
                               symbolName: symbolName,
                               spaceID: space.id)
        allFolders.append(f)
        persist()
        emit()
        return f
    }

    /// Move a tab to a new index within its space's regular-tab list.
    /// Used by the sidebar's drag-and-drop reorder.
    func moveTab(_ tab: SephrTab, toIndex newIndex: Int,
                 in space: SephrSpace) {
        // Drop out of any folder when reordering at the space's top level.
        tab.folder = nil
        tab.folderID = nil
        guard let from = allTabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        allTabs.remove(at: from)
        // Find the absolute index in `allTabs` corresponding to the
        // desired position within the space's filtered list.
        let inSpace = allTabs.filter {
            $0.spaceID == space.id && !$0.isPinned && !$0.isArchived
        }
        let target = max(0, min(newIndex, inSpace.count))
        let insertAt: Int
        if target >= inSpace.count {
            insertAt = allTabs.count
        } else if let absIdx = allTabs.firstIndex(
            where: { $0.id == inSpace[target].id }) {
            insertAt = absIdx
        } else {
            insertAt = allTabs.count
        }
        allTabs.insert(tab, at: insertAt)
        emit(); persist()
    }

    /// Unpin `tab` and drop it into `space`'s top-level list at `newIndex` —
    /// the "drag a pinned chip out of the favorites grid back into the tab
    /// list" gesture. A pin is cross-space, so landing it in a space binds
    /// it there (re-stamp `spaceID`); when that space uses a different
    /// Chromium profile the live WebContents is torn down so it recreates
    /// under the new profile, mirroring `moveTab(_:toSpace:)`. Falls back to
    /// a plain reorder if `tab` wasn't actually pinned.
    func unpinTab(_ tab: SephrTab, toIndex newIndex: Int, in space: SephrSpace) {
        guard tab.isPinned else {
            moveTab(tab, toIndex: newIndex, in: space)
            return
        }
        let oldProfile = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == tab.spaceID })?.profileID

        tab.isPinned = false
        tab.folder = nil
        tab.folderID = nil
        // The unpinned tab keeps its active flag — if the user was viewing
        // this pin, it stays the visible tab in the space it lands in (no
        // promoteActiveIfNeeded dance, since it isn't leaving the current
        // space's content).
        if oldProfile != space.profileID {
            tab.webView?.removeFromSuperview()
            tab.webView = nil
        }
        tab.spaceID = space.id

        guard let from = allTabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        allTabs.remove(at: from)
        let inSpace = allTabs.filter {
            $0.spaceID == space.id && !$0.isPinned && !$0.isArchived
        }
        let target = max(0, min(newIndex, inSpace.count))
        let insertAt: Int
        if target >= inSpace.count {
            insertAt = allTabs.count
        } else if let absIdx = allTabs.firstIndex(
            where: { $0.id == inSpace[target].id }) {
            insertAt = absIdx
        } else {
            insertAt = allTabs.count
        }
        allTabs.insert(tab, at: insertAt)
        emit(); persist()
    }

    func moveTab(_ tab: SephrTab, toFolder folder: SephrTabFolder?) {
        tab.folder = folder
        tab.folderID = folder?.id
        emit(); persist()
    }

    /// Move a tab into another space, optionally at a specific slot in
    /// that space's top-level list. Re-stamps `spaceID`, drops any folder
    /// membership, and — when the destination space uses a different
    /// Chromium profile — tears the live WebContents down so it recreates
    /// under the new profile (cookies/session follow the tab) on its next
    /// display. Used by the Manage Spaces board's cross-column drag.
    func moveTab(_ tab: SephrTab, toSpace space: SephrSpace,
                 toIndex newIndex: Int? = nil) {
        // Same space already? Fall back to a plain top-level reorder /
        // un-folder so the call is still meaningful from the board.
        guard tab.spaceID != space.id else {
            if let idx = newIndex { moveTab(tab, toIndex: idx, in: space) }
            else { moveTab(tab, toFolder: nil) }
            return
        }
        let oldSpaceID = tab.spaceID
        let oldProfile = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == oldSpaceID })?.profileID

        tab.spaceID = space.id
        tab.folder = nil
        tab.folderID = nil
        if oldProfile != space.profileID {
            tab.webView?.removeFromSuperview()
            tab.webView = nil
        }

        // Reposition within the destination space's top-level list —
        // same insertion math as `moveTab(_:toIndex:in:)`.
        if let from = allTabs.firstIndex(where: { $0.id == tab.id }) {
            allTabs.remove(at: from)
            let inSpace = allTabs.filter {
                $0.spaceID == space.id && !$0.isPinned && !$0.isArchived
            }
            let target = max(0, min(newIndex ?? inSpace.count, inSpace.count))
            let insertAt: Int
            if target >= inSpace.count {
                insertAt = allTabs.count
            } else if let absIdx = allTabs.firstIndex(
                where: { $0.id == inSpace[target].id }) {
                insertAt = absIdx
            } else {
                insertAt = allTabs.count
            }
            allTabs.insert(tab, at: insertAt)
        }

        // Posts are deferred to here — after the structural mutation —
        // so subscribers never observe a half-moved model. If we
        // carried the single global active tab out of the current
        // space, the main window would be left showing a page that now
        // belongs elsewhere: drop the active flag (no-op when the tab
        // wasn't active) and let `promoteActiveIfNeeded()` re-anchor
        // the current space.
        setActive(tab, to: false)
        promoteActiveIfNeeded()
        emit(); persist()
    }

    /// Move a whole folder — and every tab inside it — into another
    /// space. Re-stamps the folder's `spaceID` and each member tab's
    /// `spaceID` so the group travels together (members keep their folder
    /// membership). Cross-profile moves rebuild each member's WebContents.
    func moveFolder(_ folder: SephrTabFolder, toSpace space: SephrSpace) {
        guard folder.spaceID != space.id else { return }
        let oldProfile = SephrSpaceManager.shared.spaces
            .first(where: { $0.id == folder.spaceID })?.profileID
        let crossProfile = oldProfile != space.profileID

        folder.spaceID = space.id
        for tab in allTabs where tab.folderID == folder.id {
            tab.spaceID = space.id
            if crossProfile {
                tab.webView?.removeFromSuperview()
                tab.webView = nil
            }
        }
        // Deactivation deferred until after the re-stamp loop so the
        // `.active` posts observe a consistent, fully-moved model.
        // setActive no-ops for the (typical) inactive members.
        for tab in allTabs where tab.folderID == folder.id {
            setActive(tab, to: false)
        }
        promoteActiveIfNeeded()
        emit(); persist()
    }

    /// Guarantees the *current* space still has an active tab after a
    /// cross-space move that may have carried the previously-active tab
    /// out of it — so the main window isn't left showing a page that now
    /// lives in another space. No-op when the current space is empty.
    private func promoteActiveIfNeeded() {
        let cur = SephrSpaceManager.shared.currentSpace.id
        let curTabs = allTabs.filter { $0.spaceID == cur && !$0.isArchived }
        guard !curTabs.isEmpty,
              !curTabs.contains(where: { $0.isActive }) else { return }
        if let promoted = curTabs.first {
            setActive(promoted, to: true)
        }
    }

    /// Rename / re-symbol a folder in place. Persists + emits so every
    /// folder cell currently on screen redraws with the new name and
    /// icon without having to tear the sidebar's tab stack down.
    func updateFolder(_ folder: SephrTabFolder,
                      name: String, symbolName: String) {
        folder.name = name
        folder.symbolName = symbolName
        emit(); persist()
    }

    func deleteFolder(_ folder: SephrTabFolder,
                      movingTabsTo dest: SephrTabFolder? = nil) {
        for tab in allTabs where tab.folderID == folder.id {
            tab.folder = dest
            tab.folderID = dest?.id
        }
        allFolders.removeAll { $0.id == folder.id }
        emit(); persist()
    }

    func groupSelectedTabs() {
        // Bundles the active tab and its next sibling into a new folder.
        guard let active = activeTab() else { return }
        let space = SephrSpaceManager.shared.currentSpace
        let siblings = tabs(in: space)
        guard let idx = siblings.firstIndex(where: { $0.id == active.id })
        else { return }
        let grouped = [siblings[idx],
                        siblings[min(idx + 1, siblings.count - 1)]]
        guard Set(grouped.map(\.id)).count > 1 else { return }
        let folder = createFolder(name: "Group",
                                   color: space.color, in: space)
        for tab in grouped { moveTab(tab, toFolder: folder) }
    }

    // MARK: — Queries

    func tabs(in space: SephrSpace) -> [SephrTab] {
        allTabs.filter {
            $0.spaceID == space.id && !$0.isPinned && !$0.isArchived
        }
    }

    func folders(in space: SephrSpace) -> [SephrTabFolder] {
        allFolders.filter { $0.spaceID == space.id }
    }

    func allPinnedTabs() -> [SephrTab] {
        allTabs.filter { $0.isPinned && !$0.isArchived }
    }

    func archivedTabs() -> [SephrTab] {
        allTabs.filter { $0.isArchived }
    }

    // MARK: — Space lifecycle

    func freezeTabs(in space: SephrSpace) {
        for tab in allTabs where tab.spaceID == space.id {
            tab.webView?.freeze()
        }
    }

    func prepareSpace(_ space: SephrSpace) {
        let inSpace = allTabs.filter { $0.spaceID == space.id }
        let active = inSpace.first(where: { $0.isActive }) ?? inSpace.first
        active?.webView?.unfreeze()
    }

    func archiveTabs(in space: SephrSpace) {
        for tab in allTabs where tab.spaceID == space.id {
            tab.isArchived = true
            tab.webView?.freeze()
        }
        persist()
    }

    // MARK: — Auto-archive

    private func scheduleAutoArchive() {
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60,
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoArchive() }
        }
    }

    private func runAutoArchive() {
        let days = SephrPreferences.archiveAfterDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for tab in allTabs
            where !tab.isPinned && !tab.isActive && !tab.isArchived
            && tab.lastAccessedAt < cutoff {
            tab.isArchived = true
            tab.webView?.freeze()
        }
        persist()
    }

    // MARK: — Persistence helpers

    private func rebindFolderReferences() {
        let byID = Dictionary(uniqueKeysWithValues:
                              allFolders.map { ($0.id, $0) })
        for tab in allTabs {
            if let fid = tab.folderID { tab.folder = byID[fid] }
        }
    }

    /// Structure-level change (add/remove/reorder/move). Tab-scoped changes
    /// (title/url/favicon/active/loading) post TabEvent directly and must
    /// NOT call this.
    private func emit() {
        TabEventBus.shared.postStructure()
        // Legacy broadcast — removed in the cleanup task once all
        // observers are migrated to TabEventBus.
        NotificationCenter.default.post(name: .sephrTabModelChanged,
                                         object: nil)
    }

    /// Exposed so callers outside the model (e.g. SephrTab navigation
    /// callbacks updating url/title) can mark the model dirty without
    /// having to bounce through a mutation. The actual disk write is
    /// coalesced — see `persistPending`.
    func persist() {
        persistPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.writeNow()
            }
        }
        persistPending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistDebounce, execute: work)
    }

    /// Force any pending coalesced write to happen immediately. Called
    /// from the quit path so an in-flight 250 ms debounce doesn't drop
    /// the user's most recent state. Safe to call when nothing is
    /// pending — it just no-ops.
    func flushPersist() {
        if let work = persistPending {
            work.cancel()
            persistPending = nil
            writeNow()
        }
    }

    private func writeNow() {
        persistPending = nil
        SephrSessionStore.shared.saveSession(tabs: allTabs,
                                              folders: allFolders)
    }
}
