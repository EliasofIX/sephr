import AppKit
import CAL

struct SephrBoost: Codable, Identifiable {
    let id: UUID
    var host: String
    var css: String?
    var js: String?
    var isEnabled: Bool

    init(id: UUID = UUID(),
         host: String,
         css: String? = nil,
         js: String? = nil,
         isEnabled: Bool = true) {
        self.id = id
        self.host = host
        self.css = css
        self.js = js
        self.isEnabled = isEnabled
    }
}

@MainActor
final class SephrBoostManager: ObservableObject {
    static let shared = SephrBoostManager()

    @Published private(set) var boosts: [SephrBoost] = []

    // Same coalescing pattern as SephrTabModel.persist — toggling a row
    // of boosts in Settings used to write the full boosts.json blob per
    // toggle. We collapse rapid mutations into a single trailing write
    // 250 ms out and flush on quit.
    private var persistPending: DispatchWorkItem?
    private static let persistDebounce: TimeInterval = 0.25
    private var changeCounter: UInt64 = 0
    private var lastWrittenCounter: UInt64 = 0

    private init() {
        self.boosts = SephrSessionStore.shared.loadBoosts()
        applyAll()
    }

    func add(_ boost: SephrBoost) {
        boosts.append(boost)
        persist()
        apply(boost)
        NotificationCenter.default.post(name: .sephrBoostsChanged, object: nil)
    }

    func remove(_ boost: SephrBoost) {
        boosts.removeAll { $0.id == boost.id }
        CALProfile.default().removeInjections(forHost: boost.host)
        persist()
        NotificationCenter.default.post(name: .sephrBoostsChanged, object: nil)
    }

    func setEnabled(_ boost: SephrBoost, enabled: Bool) {
        guard let idx = boosts.firstIndex(where: { $0.id == boost.id }) else { return }
        boosts[idx].isEnabled = enabled
        persist()
        if enabled { apply(boosts[idx]) }
        else { CALProfile.default().removeInjections(forHost: boost.host) }
        NotificationCenter.default.post(name: .sephrBoostsChanged, object: nil)
    }

    func applyAll() {
        for b in boosts where b.isEnabled { apply(b) }
    }

    private func apply(_ boost: SephrBoost) {
        let profile = CALProfile.default()
        if let css = boost.css { profile.injectCSS(css, forHost: boost.host) }
        if let js  = boost.js  { profile.injectJS(js,  forHost: boost.host) }
    }

    private func persist() {
        changeCounter &+= 1
        persistPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.writeNow() }
        }
        persistPending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistDebounce, execute: work)
    }

    /// Force any pending coalesced write to disk now. Called from the
    /// quit path so toggling a boost a fraction of a second before quit
    /// doesn't drop the change.
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
        SephrSessionStore.shared.saveBoosts(boosts)
    }
}
