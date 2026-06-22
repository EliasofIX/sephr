import AppKit
import CAL
import Combine

/// Single source of truth for download state across the UI. Owns the
/// `CALDownloads.onDownloadsChanged` subscription for the active profile
/// and re-publishes it as Combine streams the sidebar footer button and
/// the popover panel both consume. Re-subscribes on space change so a
/// profile switch immediately reflects in the chrome.
@MainActor
final class SephrDownloadsObserver: ObservableObject {

    static let shared = SephrDownloadsObserver()

    /// All downloads for the active profile, most recent first.
    @Published private(set) var downloads: [CALDownload] = []
    /// Aggregate fraction across active downloads (in-progress + paused).
    /// 0 when no active downloads or none have known total bytes.
    @Published private(set) var activeProgress: Double = 0
    @Published private(set) var hasActive: Bool = false

    /// Fires once each time the count of *active* downloads grows — i.e.
    /// when the user kicks off a new download. The toolbar button hooks
    /// this to pulse, Arc-style.
    let downloadStarted = PassthroughSubject<Void, Never>()

    private var lastActiveCount = 0
    private var currentProfileID: String?
    /// IDs the user has dismissed via "Clear". Kept in memory only —
    /// Chromium pushes a fresh snapshot every change, so we filter
    /// these out from the published list. Cleared on quit.
    private var hiddenIDs: Set<String> = []

    /// Hide every currently-visible download from the panel. New
    /// downloads (which arrive with a fresh id) still surface normally.
    func clearVisible() {
        for d in downloads { hiddenIDs.insert(d.identifier) }
        refreshFromCache()
    }

    /// Hide a single download from the panel without clearing the rest.
    func hide(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        hiddenIDs.insert(identifier)
        refreshFromCache()
    }

    func open(_ download: CALDownload) {
        guard download.state == .complete else { return }
        let path = download.targetPath
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealInFinder(_ download: CALDownload) {
        let pid = currentProfileID ?? SephrSpaceManager.shared.currentSpace.profileID
        CALDownloads.sharedInstance(forProfile: pid)
            .reveal(inFinder: download.identifier)
    }

    func copyLink(_ download: CALDownload) {
        let link = download.sourceURL
        guard !link.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func refreshFromCache() {
        let pid = currentProfileID ?? SephrSpaceManager.shared.currentSpace.profileID
        update(CALDownloads.sharedInstance(forProfile: pid).currentDownloads())
    }

    private init() {
        attachToCurrentProfile()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSpaceChanged),
            name: .sephrSpaceChanged, object: nil)
    }

    @objc private func onSpaceChanged() { attachToCurrentProfile() }

    private func attachToCurrentProfile() {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        guard pid != currentProfileID else { return }
        currentProfileID = pid
        let svc = CALDownloads.sharedInstance(forProfile: pid)
        svc.onDownloadsChanged = { [weak self] arr in
            // Trampoline to MainActor since the callback may dispatch
            // through GCD; @MainActor ObservableObject can't be touched
            // off-main without a hop.
            Task { @MainActor [weak self] in self?.update(arr) }
        }
        update(svc.currentDownloads())
    }

    private func update(_ arr: [CALDownload]) {
        // Chromium's DownloadManager assigns monotonically increasing
        // numeric ids, so sorting by id desc puts the most recent
        // download at the top of the list.
        let sorted = arr
            .filter { !hiddenIDs.contains($0.identifier) }
            .sorted { lhs, rhs in
                (Int(lhs.identifier) ?? 0) > (Int(rhs.identifier) ?? 0)
            }
        downloads = sorted

        let active = sorted.filter {
            $0.state == .inProgress || $0.state == .paused
        }
        let newActiveCount = active.count
        if newActiveCount > lastActiveCount {
            downloadStarted.send()
        }
        lastActiveCount = newActiveCount
        let newHasActive = !active.isEmpty
        // Equality-guard @Published writes — the CALDownloads callback
        // fires on every byte-tick during a download. Without the guards
        // each tick re-publishes hasActive and activeProgress even when
        // the rounded fraction is unchanged, waking every SwiftUI
        // subscriber (toolbar pulse, panel list) for a no-op.
        if hasActive != newHasActive { hasActive = newHasActive }

        let newProgress: Double
        if newHasActive {
            let total = active.reduce(0) { $0 + max(0, $1.totalBytes) }
            let received = active.reduce(0) { $0 + max(0, $1.receivedBytes) }
            newProgress = total > 0
                ? Double(received) / Double(total)
                : 0
        } else {
            newProgress = 0
        }
        if activeProgress != newProgress { activeProgress = newProgress }
    }
}
