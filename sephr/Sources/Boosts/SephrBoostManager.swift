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

    private init() {
        self.boosts = SephrSessionStore.shared.loadBoosts()
        applyAll()
    }

    func add(_ boost: SephrBoost) {
        boosts.append(boost)
        SephrSessionStore.shared.saveBoosts(boosts)
        apply(boost)
        NotificationCenter.default.post(name: .sephrBoostsChanged, object: nil)
    }

    func remove(_ boost: SephrBoost) {
        boosts.removeAll { $0.id == boost.id }
        CALProfile.default().removeInjections(forHost: boost.host)
        SephrSessionStore.shared.saveBoosts(boosts)
        NotificationCenter.default.post(name: .sephrBoostsChanged, object: nil)
    }

    func setEnabled(_ boost: SephrBoost, enabled: Bool) {
        guard let idx = boosts.firstIndex(where: { $0.id == boost.id }) else { return }
        boosts[idx].isEnabled = enabled
        SephrSessionStore.shared.saveBoosts(boosts)
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
}
