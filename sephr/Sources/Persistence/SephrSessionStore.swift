import Foundation

/// The single persistence facade every other module talks to. Under the
/// hood this is either GRDB (if linked) or JSON files on disk — the store
/// doesn't leak that detail.
final class SephrSessionStore {
    static let shared = SephrSessionStore()

    private let db: SephrDatabase

    private init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Sephr")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sephr.sqlite").path
        self.db = try! SephrDatabase(path: path)
    }

    // MARK: — Spaces

    func saveSpaces(_ spaces: [SephrSpace], currentID: UUID) {
        let payload = SpacesFile(spaces: spaces, currentID: currentID)
        try? db.write(payload, to: "spaces.json")
    }

    func loadSpaces() -> [SephrSpace] {
        db.read(SpacesFile.self, from: "spaces.json")?.spaces ?? []
    }

    // MARK: — Session (tabs + folders)

    func saveSession(tabs: [SephrTab], folders: [SephrTabFolder]) {
        let payload = SessionFile(tabs: tabs, folders: folders)
        try? db.write(payload, to: "session.json")
    }

    func loadSession() -> SephrSession {
        guard let f = db.read(SessionFile.self, from: "session.json") else {
            return SephrSession(tabs: [], folders: [])
        }
        return SephrSession(tabs: f.tabs, folders: f.folders)
    }

    // MARK: — Boosts

    func saveBoosts(_ boosts: [SephrBoost]) {
        try? db.write(BoostsFile(boosts: boosts), to: "boosts.json")
    }

    func loadBoosts() -> [SephrBoost] {
        db.read(BoostsFile.self, from: "boosts.json")?.boosts ?? []
    }

    // MARK: — Lifecycle

    /// Block until every dispatched blob write has reached disk. Called
    /// from the quit path so the user's most recent state survives even
    /// when the run loop tears down before the background queue would
    /// have drained on its own.
    func flush() { db.flushBlobWrites() }

    // MARK: — File payloads

    private struct SpacesFile: Codable {
        var spaces: [SephrSpace]
        var currentID: UUID
    }

    private struct SessionFile: Codable {
        var tabs: [SephrTab]
        var folders: [SephrTabFolder]
    }

    private struct BoostsFile: Codable {
        var boosts: [SephrBoost]
    }
}
