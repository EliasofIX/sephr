import Foundation

/// Holds the single active split-tab group — the two tabs that are shown
/// side by side. This is the *grouping*, which is distinct from whether
/// the split is currently displayed on screen: the group persists in the
/// sidebar (rendered as one combined pill, Zen-style) until the user
/// explicitly breaks it via a pane's expand button. Switching to some
/// other tab merely hides the split view; the group survives.
///
/// One group at a time, two tabs. Not persisted across relaunch yet.
final class SephrSplitManager {
    static let shared = SephrSplitManager()
    private init() {}

    private(set) var primaryID: UUID?
    private(set) var secondaryID: UUID?

    var hasGroup: Bool { primaryID != nil && secondaryID != nil }

    func contains(_ id: UUID) -> Bool {
        id == primaryID || id == secondaryID
    }

    func setGroup(primary: UUID, secondary: UUID) {
        guard primaryID != primary || secondaryID != secondary else { return }
        primaryID = primary
        secondaryID = secondary
        notify()
    }

    func clear() {
        guard hasGroup else { return }
        primaryID = nil
        secondaryID = nil
        notify()
    }

    /// Dissolves the group if it references a tab that no longer exists —
    /// e.g. one of the split members was closed. Returns true if cleared.
    @discardableResult
    func clearIfMemberMissing(in tabIDs: Set<UUID>) -> Bool {
        guard let p = primaryID, let s = secondaryID else { return false }
        guard !tabIDs.contains(p) || !tabIDs.contains(s) else { return false }
        clear()
        return true
    }

    private func notify() {
        NotificationCenter.default.post(name: .sephrTabModelChanged, object: nil)
    }
}
