import AppKit

/// Disk-backed favicon cache keyed by URL host. Populated when CAL
/// hands us a fresh favicon via the Chromium bridge; read on session
/// load so tab cells render the page's icon immediately rather than
/// waiting for Chromium to re-fetch it.
///
/// Thread model: a single serial queue guards both the in-memory map
/// and the on-disk PNGs. Reads return synchronously (so an
/// `SephrTab.init(from:)` running off the main actor can hit the
/// cache without an actor hop). Writes are async so persisting an
/// icon doesn't block whatever main-thread code just received it.
final class SephrFaviconCache: @unchecked Sendable {

    static let shared = SephrFaviconCache()

    private let queue = DispatchQueue(
        label: "sephr.faviconCache", qos: .utility)
    private var memoryCache: [String: NSImage] = [:]
    /// Hosts we've already disk-checked and found nothing for. Without
    /// this, every cell rebuild repeats the same `Data(contentsOf:)`
    /// for every host the user has never visited — the sidebar's
    /// notification cycle can issue dozens of those per interaction.
    /// Cleared by `set(_:for:)` so a freshly-arrived favicon promotes
    /// out of the miss set.
    private var negativeCache: Set<String> = []
    private let directory: URL

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        self.directory = support
            .appendingPathComponent("Sephr/Favicons")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    /// Returns the cached icon for `urlString`'s host, if any. Promotes
    /// disk hits into the memory cache and remembers misses so repeated
    /// cold lookups for the same never-visited host short-circuit
    /// without re-hitting disk. Returns `nil` if the URL has no host
    /// (e.g. `about:blank`).
    func get(for urlString: String) -> NSImage? {
        guard let host = Self.host(for: urlString) else { return nil }
        return queue.sync {
            if let cached = memoryCache[host] { return cached }
            if negativeCache.contains(host) { return nil }
            let file = directory.appendingPathComponent("\(host).png")
            guard let data = try? Data(contentsOf: file),
                  let image = NSImage(data: data) else {
                negativeCache.insert(host)
                return nil
            }
            memoryCache[host] = image
            return image
        }
    }

    /// Memory-only synchronous lookup — never touches disk. Safe on any
    /// thread at any frequency.
    func cached(for urlString: String) -> NSImage? {
        guard let host = Self.host(for: urlString) else { return nil }
        return queue.sync { memoryCache[host] }
    }

    /// Async disk-backed lookup. Completion always fires on the main
    /// queue (including the no-host early return) so callers can update
    /// UI state without re-dispatching.
    func load(for urlString: String,
              completion: @escaping @Sendable (NSImage?) -> Void) {
        guard let host = Self.host(for: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async { [self] in
            var result: NSImage? = memoryCache[host]
            if result == nil, !negativeCache.contains(host) {
                let file = directory.appendingPathComponent("\(host).png")
                if let data = try? Data(contentsOf: file),
                   let image = NSImage(data: data) {
                    memoryCache[host] = image
                    result = image
                } else {
                    negativeCache.insert(host)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Persists `image` as the canonical favicon for `urlString`'s
    /// host. Subsequent `get(for:)` calls for that host return this
    /// image — both this session (in memory) and on relaunch (on disk).
    func set(_ image: NSImage, for urlString: String) {
        guard let host = Self.host(for: urlString) else { return }
        queue.async { [self] in
            memoryCache[host] = image
            negativeCache.remove(host)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png,
                                                properties: [:]) else {
                return
            }
            let file = directory.appendingPathComponent("\(host).png")
            try? png.write(to: file)
        }
    }

    private static func host(for urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host(percentEncoded: false)
                ?? url.host else { return nil }
        let lower = host.lowercased()
        // The host gets used unmodified as a filename; reject anything
        // that would resolve outside the favicons directory.
        guard !lower.contains("/"), !lower.contains("\0"),
              lower != ".", lower != ".." else { return nil }
        return lower
    }
}
