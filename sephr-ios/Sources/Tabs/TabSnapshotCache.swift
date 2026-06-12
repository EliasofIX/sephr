import UIKit

/// Snapshots backing the tab deck cards. Two tiers: an NSCache of UIImages
/// (memory-pressure aware, evicted automatically) over JPEGs on disk so
/// cards survive relaunch. Disk writes happen off the main thread.
final class TabSnapshotCache: @unchecked Sendable {
    static let shared = TabSnapshotCache()

    private let memory = NSCache<NSUUID, UIImage>()
    private let dir: URL
    private let io = DispatchQueue(label: "com.sephr.ios.snapshots",
                                   qos: .utility)

    private init() {
        memory.countLimit = 24
        dir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    func store(_ image: UIImage, for id: UUID, persistToDisk: Bool) {
        memory.setObject(image, forKey: id as NSUUID)
        guard persistToDisk else { return }
        let url = fileURL(id)
        io.async {
            try? image.jpegData(compressionQuality: 0.6)?
                .write(to: url, options: .atomic)
        }
    }

    func image(for id: UUID) -> UIImage? {
        if let cached = memory.object(forKey: id as NSUUID) { return cached }
        guard let image = UIImage(contentsOfFile: fileURL(id).path) else {
            return nil
        }
        memory.setObject(image, forKey: id as NSUUID)
        return image
    }

    /// Drop the memory copy but keep the disk copy (archived tabs).
    func evict(_ id: UUID) {
        memory.removeObject(forKey: id as NSUUID)
    }

    /// Remove both tiers (closed tabs).
    func remove(_ id: UUID) {
        memory.removeObject(forKey: id as NSUUID)
        let url = fileURL(id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }
}
