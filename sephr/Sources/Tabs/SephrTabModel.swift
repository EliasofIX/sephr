import AppKit
import Combine
import SephrKit

@MainActor
final class SephrTabModel {
    static let shared = SephrTabModel()

    // No SwiftUI / Combine consumers — every reader hits the TabEventBus
    // structure channel or reads the array directly. ObservableObject /
    // @Published would just fire objectWillChange on every mutation for
    // nobody to listen to.
    private(set) var allTabs: [SephrTab] = []
    private(set) var allFolders: [SephrTabFolder] = []

    /// Monotonic counter bumped on every structural change (add / remove /
    /// reorder / move / pin / folder). Sidebar / Favorites / split UI store
    /// the last value they rendered and skip rebuilds when it hasn't moved,
    /// instead of allocating + comparing ~5KB structure-key strings each
    /// time. Wraps with `&+` so the model never has to fear overflow.
    private(set) var structureGeneration: UInt64 = 0

    /// Cached active tab so `activeTab()` is O(1) and `activateTab` skips
    /// the O(N) deactivate loop. Updated by `setActive`.
    private weak var cachedActiveTab: SephrTab?

    /// Lazy O(1) indexes over `allTabs`. Built on first read, dropped on
    /// every structural change (`emit()`) and archive sweep so a stale
    /// slot can never resolve to the wrong tab. Replaces the
    /// `firstIndex(where: $0.id == ...)` / `first(where: webView === ...)`
    /// scans that ran on every tab close / move / swap.
    private var _tabIndex: [UUID: Int]?
    private var _tabByWebView: [ObjectIdentifier: SephrTab]?
    private var _tabsByFolder: [UUID: [SephrTab]]?

    private func invalidateLookups() {
        _tabIndex = nil
        _tabByWebView = nil
        _tabsByFolder = nil
    }

    /// `allTabs.firstIndex { $0.id == id }` in O(1) amortized.
    private func indexOfTab(id: UUID) -> Int? {
        if let cache = _tabIndex { return cache[id] }
        var dict = [UUID: Int](minimumCapacity: allTabs.count)
        for (i, t) in allTabs.enumerated() { dict[t.id] = i }
        _tabIndex = dict
        return dict[id]
    }

    func tab(withID id: UUID) -> SephrTab? {
        indexOfTab(id: id).map { allTabs[$0] }
    }

    /// O(1) reverse lookup from a live CALWebView pointer to the tab that
    /// owns it. Used by the window controller's tab-swap path, which used
    /// to scan `allTabs` on every showTab.
    func tab(owning webView: AnyObject) -> SephrTab? {
        let key = ObjectIdentifier(webView)
        if let cache = _tabByWebView { return cache[key] }
        var dict = [ObjectIdentifier: SephrTab](minimumCapacity: allTabs.count)
        for t in allTabs {
            if let wv = t.webView { dict[ObjectIdentifier(wv)] = t }
        }
        _tabByWebView = dict
        return dict[key]
    }

    /// O(1) folder member list. `SephrFolderCell.reload()` calls this on
    /// every expand/collapse — used to walk `allTabs` end-to-end per folder.
    func tabs(inFolder folderID: UUID) -> [SephrTab] {
        if let cache = _tabsByFolder { return cache[folderID] ?? [] }
        var dict = [UUID: [SephrTab]]()
        for t in allTabs {
            if let fid = t.folderID { dict[fid, default: []].append(t) }
        }
        _tabsByFolder = dict
        return dict[folderID] ?? []
    }

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

    /// Bumped by persist(); writeNow() skips the encode when nothing new
    /// was marked dirty since the last successful write.
    private var changeCounter: UInt64 = 0
    private var lastWrittenCounter: UInt64 = 0

    private init() {
        let session = SephrSessionStore.shared.loadSession()
        self.allTabs = session.tabs
        self.allFolders = session.folders
        self.cachedActiveTab = session.tabs.first { $0.isActive }
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
        emit()              // structural: tab list now includes this tab
        activateTab(tab)    // activates + persists (no structure re-fire)
        return tab
    }

    /// Create a Note — an Arc-easel-style native canvas that lives in the
    /// sidebar like a tab but never owns a WebContents. Its drawing
    /// document persists separately under App Support/Sephr/Notes/<id>/;
    /// the session only records the tab shell (id, kind, title, space).
    @discardableResult
    func newNote(in space: SephrSpace) -> SephrTab {
        let tab = SephrTab(kind: .note, url: "",
                           title: "Untitled Note", spaceID: space.id)
        allTabs.append(tab)
        emit()              // structural: tab list now includes this note
        activateTab(tab)    // activates + persists (no structure re-fire)
        return tab
    }

    /// Reattach a tab shell for a note that still exists on disk but was
    /// closed from the sidebar. Used by the Notes library.
    @discardableResult
    func reopenNote(id: UUID, title: String, in space: SephrSpace) -> SephrTab {
        if let existing = tab(withID: id) { return existing }
        let tab = SephrTab(id: id, kind: .note, url: "",
                           title: title, spaceID: space.id)
        allTabs.append(tab)
        emit()
        return tab
    }

    /// Pull an archived tab back into the live sidebar.
    func restoreFromArchive(_ tab: SephrTab) {
        guard tab.isArchived else { return }
        tab.isArchived = false
        tab.lastAccessedAt = Date()
        emit()
        activateTab(tab)
    }

    /// Rename a tab in place (the Note canvas's title field edits the
    /// sidebar title live). Posts `.title` so the cell refreshes without
    /// a structural rebuild.
    func renameTab(_ tab: SephrTab, title: String) {
        guard tab.title != title else { return }
        tab.title = title
        TabEventBus.shared.post(TabEvent(tabID: tab.id, kind: .title))
        persist()
    }

    func closeTab(_ tab: SephrTab) {
        // Closing the tab you're viewing hands focus to the tab above it
        // in the sidebar (Arc-style) so the window never blanks out.
        // Resolve the target BEFORE the structural removal, while the
        // sibling order still includes `tab`. Closing a *background* tab
        // leaves the active tab alone (promote stays nil).
        let promote = tab.isActive ? activationTarget(closing: tab) : nil

        // Closing a split member dissolves the whole group — a half-empty
        // split pill would be meaningless.
        if SephrSplitManager.shared.contains(tab.id) {
            SephrSplitManager.shared.clear()
        }
        // Snapshot for Cmd+Shift+T before the structural removal, while
        // we can still record where the tab sat in `allTabs`.
        recordClosedTab(tab)
        tab.webView?.removeFromSuperview()
        allTabs.removeAll { $0.id == tab.id }

        if let promote {
            // The removal itself is the structural change; activateTab
            // only fires the active-change channel + persists, so we
            // emit explicitly here for sidebar/favorites/now-playing-pill.
            emit()
            activateTab(promote)
        } else {
            emit(); persist()
        }
    }

    /// After the active `tab` closes, the tab to activate in its place:
    /// the one visually above it in the sidebar, or — if it was the first
    /// in its group — the one below. Falls back to any remaining tab in
    /// its space so a space never ends up with no active tab while tabs
    /// remain. nil when nothing is left to show.
    private func activationTarget(closing tab: SephrTab) -> SephrTab? {
        let peers = closeNeighbors(of: tab)
        if let idx = peers.firstIndex(where: { $0.id == tab.id }) {
            if idx > 0 { return peers[idx - 1] }          // above
            if peers.count > 1 { return peers[idx + 1] }  // was first → below
        }
        // The tab's visual group emptied (e.g. it was the only member of
        // its folder): keep the space alive by promoting any other tab.
        return allTabs.first {
            $0.id != tab.id && $0.spaceID == tab.spaceID && !$0.isArchived
        }
    }

    /// The sibling list used to pick a close-neighbor, in sidebar order.
    /// A tab peers with its own visual group so focus never jumps across a
    /// boundary: a pinned tab with the favorites grid, a folder member
    /// with its folder, a top-level tab with the space's top-level tabs.
    private func closeNeighbors(of tab: SephrTab) -> [SephrTab] {
        if tab.isPinned { return allPinnedTabs() }
        let inSpace = allTabs.filter {
            $0.spaceID == tab.spaceID && !$0.isPinned && !$0.isArchived
        }
        if let fid = tab.folderID {
            return inSpace.filter { $0.folderID == fid }
        }
        return inSpace.filter { $0.folderID == nil }
    }

    /// Close every tab in the same sidebar group as `tab` except `tab` itself
    /// (Chrome's "Close other tabs"). Pinned tabs are always preserved.
    func closeOtherTabs(keeping tab: SephrTab) {
        let victims = closeNeighbors(of: tab).filter {
            $0.id != tab.id && !$0.isPinned
        }
        closeBatch(victims, fallbackActive: tab)
    }

    /// Close tabs sitting visually below `tab` in the same sidebar group
    /// (Chrome's "Close tabs to the right"). Pinned tabs are always preserved.
    func closeTabsBelow(_ tab: SephrTab) {
        let peers = closeNeighbors(of: tab)
        guard let idx = peers.firstIndex(where: { $0.id == tab.id }) else { return }
        let victims = peers.suffix(from: idx + 1).filter { !$0.isPinned }
        closeBatch(victims, fallbackActive: tab)
    }

    /// Remove `victims` in a single structural mutation: one `allTabs`
    /// rewrite + one `emit()` + one debounced persist, instead of N
    /// individual `closeTab(...)` calls (each of which fires structure
    /// posts and triggers a full sidebar rebuild). When the currently
    /// active tab is itself a victim, focus is handed to `fallbackActive`.
    private func closeBatch(_ victims: [SephrTab],
                            fallbackActive: SephrTab) {
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        let active = activeTab()
        let needsPromote =
            active.map { victimIDs.contains($0.id) } ?? false
        let split = SephrSplitManager.shared
        for v in victims {
            if split.contains(v.id) { split.clear() }
            recordClosedTab(v)
            v.webView?.removeFromSuperview()
        }
        // Single linear pass instead of N successive removeAll calls.
        allTabs.removeAll { victimIDs.contains($0.id) }
        if needsPromote, !victimIDs.contains(fallbackActive.id) {
            emit()
            activateTab(fallbackActive)
        } else {
            emit(); persist()
        }
    }

    /// Open a new tab with the same URL, immediately after `tab` in the
    /// sidebar. Becomes active, like Chrome's "Duplicate".
    @discardableResult
    func duplicateTab(_ tab: SephrTab) -> SephrTab {
        let url = tab.webView?.currentURL ?? tab.url
        let copy = SephrTab(kind: tab.kind, url: url, title: tab.title,
                            spaceID: tab.spaceID)
        copy.folderID = tab.folderID
        copy.isPinned = tab.isPinned
        if let i = indexOfTab(id: tab.id) {
            allTabs.insert(copy, at: i + 1)
        } else {
            allTabs.append(copy)
        }
        emit()              // structural: tab list now includes the copy
        activateTab(copy)   // activates + persists (no structure re-fire)
        return copy
    }

    func closeActiveTab() {
        guard let tab = activeTab() else { return }
        closeTab(tab)
    }

    // MARK: — Reopen closed tab (Cmd+Shift+T)

    /// A closed tab's restorable state plus where it sat in `allTabs`, so
    /// reopening drops it back roughly where it was in the sidebar. We keep
    /// the original `id` — the live object is gone by the time we restore,
    /// so there's nothing to collide with.
    private struct ClosedTab {
        let id: UUID
        let kind: SephrTab.Kind
        let url: String
        let title: String
        let spaceID: UUID
        let folderID: UUID?
        let isPinned: Bool
        let createdAt: Date
        let index: Int
    }

    /// LIFO stack of recently-closed tabs (oldest first, newest last).
    /// Capped so a long session can't grow it without bound; this is
    /// runtime-only and intentionally not persisted across launches.
    private var closedTabs: [ClosedTab] = []
    private static let maxClosedTabs = 25

    private func recordClosedTab(_ tab: SephrTab) {
        guard let idx = indexOfTab(id: tab.id) else { return }
        closedTabs.append(ClosedTab(
            id: tab.id, kind: tab.kind, url: tab.url, title: tab.title,
            spaceID: tab.spaceID, folderID: tab.folderID,
            isPinned: tab.isPinned, createdAt: tab.createdAt, index: idx))
        if closedTabs.count > Self.maxClosedTabs {
            closedTabs.removeFirst(closedTabs.count - Self.maxClosedTabs)
        }
    }

    /// Re-create the most-recently-closed tab. Restores its URL, title,
    /// pin state and — when they still exist — its space and folder,
    /// reinserts it at its old slot, brings its space forward if needed,
    /// and activates it. No-op when nothing has been closed.
    func reopenLastClosedTab() {
        guard let snap = closedTabs.popLast() else { return }

        // The space may have been deleted since the tab closed; fall back
        // to the current space (and drop the now-orphaned folder) rather
        // than resurrecting into a space that's gone.
        let spaceExists = SephrSpaceManager.shared.spaces
            .contains { $0.id == snap.spaceID }
        let targetSpaceID = spaceExists
            ? snap.spaceID
            : SephrSpaceManager.shared.currentSpace.id
        // The folder can also have been deleted independently of its space.
        let folder = (spaceExists ? snap.folderID : nil).flatMap { fid in
            allFolders.first { $0.id == fid }
        }

        let tab = SephrTab(id: snap.id,
                           kind: snap.kind,
                           url: snap.url,
                           title: snap.title,
                           spaceID: targetSpaceID,
                           folderID: folder?.id,
                           isPinned: snap.isPinned,
                           createdAt: snap.createdAt)
        tab.folder = folder
        // A reopened note finds its drawing document still on disk —
        // closing a note never deletes its content, only the sidebar item.
        if tab.kind == .web {
            _ = tab.getOrCreateWebView()   // warm so the first paint is snappy
        }

        let insertAt = max(0, min(snap.index, allTabs.count))
        allTabs.insert(tab, at: insertAt)

        // Bring the tab's space forward so the reopened tab is actually
        // visible before we focus it.
        if spaceExists,
           SephrSpaceManager.shared.currentSpace.id != targetSpaceID,
           let space = SephrSpaceManager.shared.spaces
               .first(where: { $0.id == targetSpaceID }) {
            SephrSpaceManager.shared.switchToSpace(space)
        }
        // emit() rebuilds the sidebar (structural insert), then
        // activateTab posts on the active-channel + persists.
        emit()
        activateTab(tab)
    }

    func activateTab(_ tab: SephrTab) {
        // Activate the target FIRST, then deactivate the previously-active
        // one (we cache the ref, so it's O(1) instead of an O(N) walk over
        // `allTabs`). The old tab's `.active` post must observe a model
        // where `activeTab()` already resolves to the new tab — the URL
        // field re-anchors its per-tab subscription from exactly that
        // event. Re-activation posts nothing — setActive only fires on an
        // actual flag change.
        tab.lastAccessedAt = Date()
        // Wake a slept renderer BEFORE the `.active` post — subscribers
        // (window controller showTab, URL field) read the web view from
        // their handlers and expect it live. wake() re-navigates to the
        // last committed URL; it also heals a view whose creation failed
        // at boot (isAsleep is true for that case too).
        if let wv = tab.webView, wv.isAsleep { wv.wake() }
        let previous = cachedActiveTab
        setActive(tab, to: true)
        if let previous, previous !== tab {
            setActive(previous, to: false)
        }
        // Persist so the "which tab was selected" state survives a
        // relaunch — otherwise the previously-active tab from the
        // saved session is the one that opens, not the one the user
        // last clicked. No structure `emit()` — a plain activation
        // isn't a structural change; the window controller listens on
        // the lighter active-change channel for sync-to-active.
        TabEventBus.shared.postActiveChange()
        persist()
    }

    /// Single source of truth for `isActive` flips: changes the flag
    /// and posts `.active` — only on an actual change. The post is
    /// synchronous and subscribers read the model from their handlers,
    /// so call sites must not invoke this mid-mutation: complete the
    /// structural change first, then flip.
    private func setActive(_ tab: SephrTab, to flag: Bool) {
        guard tab.isActive != flag else { return }
        tab.isActive = flag
        if flag {
            cachedActiveTab = tab
        } else if cachedActiveTab === tab {
            cachedActiveTab = nil
        }
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
        // Fast path via cache. The walk-and-heal fallback covers the case
        // where setActive was bypassed (legacy callers writing `.isActive`
        // directly), and updates the cache so the next call is O(1).
        if let cached = cachedActiveTab, cached.isActive { return cached }
        let found = allTabs.first { $0.isActive }
        cachedActiveTab = found
        return found
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
            guard let wv = tab.webView else { continue }
            // Don't freeze a tab that's actively playing audio or holds a
            // live media session — freeze() pairs WasHidden with
            // SetPageFrozen, and the page-freeze halts media playback. Leaving
            // a space should keep its music/video going (the Now Playing pill
            // surfaces it and jumps back). The tab stays hidden+unfrozen, so
            // its JS timers are still throttled (WasHidden) — only the audio
            // pipeline keeps running. `tab.isAudible` is the Swift-side
            // cache populated by `onAudioStateChange` — same value as
            // `wv.isAudible` but no CAL bridge call.
            if tab.isAudible || tab.isMediaControllable { continue }
            wv.freeze()
        }
    }

    func prepareSpace(_ space: SephrSpace) {
        let inSpace = allTabs.filter { $0.spaceID == space.id }
        let active = inSpace.first(where: { $0.isActive }) ?? inSpace.first
        active?.webView?.unfreeze()
    }

    func archiveTabs(in space: SephrSpace) {
        var didArchive = false
        for tab in allTabs where tab.spaceID == space.id && !tab.isArchived {
            tab.isArchived = true
            tab.webView?.freeze()
            didArchive = true
        }
        if didArchive { persist() }
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
        var didArchive = false
        for tab in allTabs
            where !tab.isPinned && !tab.isActive && !tab.isArchived
            && tab.lastAccessedAt < cutoff {
            tab.isArchived = true
            tab.webView?.freeze()
            didArchive = true
        }
        // Sleep AFTER the archive loop: any tab old enough to archive
        // (days) is far past the sleep threshold (minutes), so the sweep
        // immediately supersedes the freeze above by destroying the
        // WebContents outright — freeze-then-sleep in one pass is
        // redundant but harmless, and keeps archive semantics unchanged
        // for tabs that are archived but still recent enough to stay live.
        runSleepSweep()
        // Skip the full-session JSON encode + atomic disk write when this
        // sweep didn't actually change anything — defends the dirty-counter
        // guard in writeNow() from being defeated by a 60s idle poke.
        if didArchive { persist() }
    }

    /// Sleep renderers of long-hidden tabs. Exemptions: active tab,
    /// pinned tabs, tabs playing audio, members of the current split
    /// group. Failure mode is benign: a slept tab re-navigates to its
    /// stored URL on activation (wake), never a blank tab.
    private func runSleepSweep() {
        let minutes = SephrPreferences.sleepAfterMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        // Pre-filter cheap predicates — pinned / active / recently-touched
        // tabs short-circuit before we ask CAL anything. `tab.isAudible`
        // is the Swift-side cache, no bridge call. We still need
        // `wv.isAsleep` to skip already-slept renderers because there's
        // no per-Swift mirror of that state (it's set inside Chromium).
        let split = SephrSplitManager.shared
        for tab in allTabs {
            if tab.isActive || tab.isPinned { continue }
            if tab.lastAccessedAt >= cutoff { continue }
            if tab.isAudible { continue }
            if split.isInActiveSplit(tab.id) { continue }
            guard let wv = tab.webView, !wv.isAsleep else { continue }
            wv.sleep()
        }
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
        // Single monotonic counter — subscribers compare U64s instead of
        // building+comparing structure-key strings. Bumps must precede
        // postStructure() so subscribers see the new value in-handler.
        structureGeneration &+= 1
        invalidateLookups()
        TabEventBus.shared.postStructure()
        // Legacy `.sephrTabModelChanged` Notification broadcast retired —
        // every observer migrated to TabEventBus.subscribeStructure.
    }

    /// Exposed so callers outside the model (e.g. SephrTab navigation
    /// callbacks updating url/title) can mark the model dirty without
    /// having to bounce through a mutation. The actual disk write is
    /// coalesced — see `persistPending`.
    func persist() {
        changeCounter &+= 1
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
        guard changeCounter != lastWrittenCounter else { return }
        lastWrittenCounter = changeCounter
        SephrSessionStore.shared.saveSession(tabs: allTabs,
                                              folders: allFolders)
    }
}
