import Foundation

#if canImport(GRDB)
import GRDB

/// Thin wrapper around a GRDB DatabaseQueue that all persistence layers
/// funnel through. Holds the migrator definition for schema v1.
///
/// Until call sites move to typed queries against the per-entity tables,
/// `read`/`write` mirror the JSON-file API of the fallback branch and
/// keep blobs in a single `kv` table. That lets SephrSessionStore share
/// code paths across GRDB and fallback builds while we incrementally
/// migrate.
final class SephrDatabase {
    let queue: DatabaseQueue
    private let blobRoot: URL
    /// Serial queue ordering encode-then-write for blob writes. Writes
    /// dispatch async (callers — usually on @MainActor — return without
    /// blocking on JSON encode + disk IO), but ordering is preserved
    /// per-key because the queue is serial.
    private let writeQueue = DispatchQueue(
        label: "sephr.db.write", qos: .utility)
    /// Tracks in-flight writes so `flushBlobWrites()` can wait for them
    /// during the quit path.
    private let inFlight = DispatchGroup()

    init(path: String) throws {
        self.queue = try DatabaseQueue(path: path)
        self.blobRoot = URL(fileURLWithPath:
            (path as NSString).deletingLastPathComponent)
        try migrate()
    }

    /// JSON-blob write keyed by `file` (same key the fallback uses for its
    /// on-disk filename). Stored as a flat file under blobRoot so we can
    /// move to a GRDB `kv` table later without changing callers.
    ///
    /// Returns immediately — the encode + write hops onto a serial
    /// background queue. Failures are logged. The legacy `throws` is
    /// retained so call sites keep their `try?` idiom; the throw point
    /// itself is now reserved for input-validation problems (currently
    /// none) so this function never actually throws on the happy path.
    func write<T: Encodable>(_ value: T, to file: String) throws {
        let url = blobRoot.appendingPathComponent(file)
        inFlight.enter()
        writeQueue.async { [inFlight] in
            defer { inFlight.leave() }
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[sephr/db] write %@ failed: %@",
                      file as NSString, error.localizedDescription as NSString)
            }
        }
    }

    func read<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = blobRoot.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Block until every queued blob write has reached disk. Quit path
    /// only — see `SephrSessionStore.flush()`.
    func flushBlobWrites() { inFlight.wait() }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "spaces", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("data", .blob).notNull()
                t.column("isCurrent", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "tabs", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "folders", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "boosts", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
        }
        try migrator.migrate(queue)
    }
}

#else

/// Fallback when GRDB isn't linked — plain-file JSON storage in
/// Application Support. Sufficient for v1; swap-in with zero API delta
/// once GRDB is vendored via SPM.
final class SephrDatabase {
    let root: URL
    private let writeQueue = DispatchQueue(
        label: "sephr.db.write", qos: .utility)
    private let inFlight = DispatchGroup()

    init(path: String) throws {
        self.root = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    func write<T: Encodable>(_ value: T, to file: String) throws {
        let url = root.appendingPathComponent(file)
        inFlight.enter()
        writeQueue.async { [inFlight] in
            defer { inFlight.leave() }
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[sephr/db] write %@ failed: %@",
                      file as NSString, error.localizedDescription as NSString)
            }
        }
    }

    func read<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = root.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func flushBlobWrites() { inFlight.wait() }
}

#endif
