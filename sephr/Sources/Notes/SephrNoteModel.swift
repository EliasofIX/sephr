import AppKit
import SwiftUI
import SephrKit

// MARK: — Tools

/// Modal canvas tools. Image insert and page capture are one-shot
/// actions on the toolbar, not modes, so they don't appear here.
enum SephrNoteTool: CaseIterable {
    case select
    case draw
    case text
    case rect
    case ellipse
    case arrow
}

// MARK: — Element

/// One item on a Note canvas. Every element has a frame; kind-specific
/// payloads ride along as optionals so the whole document stays a flat,
/// versionable JSON array.
struct SephrNoteElement: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case stroke   // freehand ink — `points` relative to the frame origin
        case text     // editable text — `text` + `fontSize`
        case rect
        case ellipse
        case arrow    // `points` holds exactly [start, end], frame-relative
        case image    // PNG asset on disk — `imageName`
    }

    let id: UUID
    var kind: Kind
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var points: [CGPoint]?
    var text: String?
    var fontSize: CGFloat?
    var imageName: String?
    var z: Int

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x; y = newValue.origin.y
            width = newValue.size.width; height = newValue.size.height
        }
    }
}

// MARK: — Store

/// Owns one Note's document: the element list, selection/tool state, the
/// undo history, and persistence. One JSON file plus PNG assets under
/// Application Support/Sephr/Notes/<noteID>/. Saves are debounced and
/// written off the main actor; closing the tab never deletes the
/// directory, so a reopened note finds its content intact.
@MainActor
final class SephrNoteStore: ObservableObject {

    let noteID: UUID

    @Published var elements: [SephrNoteElement] = [] {
        didSet { _zSortedCache = nil; _elementIndex = nil }
    }

    /// Cached `elements` sorted by z, paying the O(n log n) once per
    /// mutation instead of once per Canvas redraw. The draft path
    /// (continuous freehand) was sorting an unchanged array every frame.
    private var _zSortedCache: [SephrNoteElement]?
    var elementsSortedByZ: [SephrNoteElement] {
        if let cached = _zSortedCache { return cached }
        let sorted = elements.sorted { $0.z < $1.z }
        _zSortedCache = sorted
        return sorted
    }

    /// Cached id → index lookup for `element(_:)`. The select tool calls
    /// it on every drag frame, and undo/redo gates on identity too — an
    /// O(n) linear scan was paid per call.
    private var _elementIndex: [UUID: Int]?
    private func ensureIndex() {
        if _elementIndex == nil {
            var m: [UUID: Int] = [:]
            m.reserveCapacity(elements.count)
            for (i, e) in elements.enumerated() { m[e.id] = i }
            _elementIndex = m
        }
    }
    @Published var selectedID: UUID?
    /// Element currently in text-edit mode (its TextField is focused).
    @Published var editingTextID: UUID?
    @Published var tool: SephrNoteTool = .select
    /// Decoded PNG assets keyed by `imageName`. Published so the canvas
    /// repaints when an async decode lands.
    @Published private(set) var images: [String: NSImage] = [:]

    private var maxZ = 0
    private var undoStack: [[SephrNoteElement]] = []
    private var redoStack: [[SephrNoteElement]] = []
    private static let maxUndoDepth = 60

    /// Save coalescing. `saveDeadline` is the timestamp the next disk
    /// write should land at; every save() call pushes it forward by
    /// `saveDebounce`. `saveScheduled` gates a one-shot checkpoint
    /// dispatched on the main queue; it re-arms itself if the deadline
    /// moved while it was sleeping. The old pattern allocated a new
    /// DispatchWorkItem on EVERY save() — at 60 Hz drag frames that's
    /// 60 allocs+cancels per second. This pattern allocates one closure
    /// per ~300 ms window of continuous saves regardless of call rate.
    private var saveDeadline: DispatchTime?
    private var saveScheduled = false
    private static let saveDebounce: TimeInterval = 0.3
    private static let writeQueue = DispatchQueue(
        label: "sephr.note.write", qos: .utility)

    private var undoObservers: [NSObjectProtocol] = []

    init(noteID: UUID) {
        self.noteID = noteID
        load()
        // Cmd+Z / Cmd+Shift+Z are swallowed app-wide by the keyboard
        // shortcut monitor (Chromium would otherwise race us for them);
        // for note tabs it reposts them as notifications carrying the
        // note's tab ID.
        let nc = NotificationCenter.default
        undoObservers.append(nc.addObserver(
            forName: .sephrNoteUndo, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? UUID == self.noteID else { return }
                self.undo()
            }
        })
        undoObservers.append(nc.addObserver(
            forName: .sephrNoteRedo, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? UUID == self.noteID else { return }
                self.redo()
            }
        })
    }

    deinit {
        for o in undoObservers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: Persistence

    nonisolated static func directory(for noteID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                  in: .userDomainMask)[0]
            .appendingPathComponent("Sephr/Notes/\(noteID.uuidString)")
    }

    private var directory: URL { Self.directory(for: noteID) }
    private var documentURL: URL {
        directory.appendingPathComponent("note.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: documentURL),
              let decoded = try? JSONDecoder()
                  .decode([SephrNoteElement].self, from: data) else { return }
        elements = decoded
        maxZ = elements.map(\.z).max() ?? 0
        for el in elements where el.kind == .image {
            if let name = el.imageName { loadImage(named: name) }
        }
    }

    /// Coalesce to a single trailing write `saveDebounce` (300 ms) after
    /// the last call; encode + disk IO happen on `writeQueue`. Cheap
    /// enough to call from per-drag-frame `update(_:)` — the only
    /// allocation per active 300 ms window is the single checkpoint
    /// closure scheduled below.
    func save() {
        saveDeadline = .now() + Self.saveDebounce
        guard !saveScheduled else { return }
        saveScheduled = true
        scheduleSaveCheckpoint()
    }

    /// Fire 300 ms from now. At fire time: if save() bumped the deadline
    /// since we slept, re-arm; otherwise commit the snapshot.
    private func scheduleSaveCheckpoint() {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.saveDebounce
        ) { [weak self] in
            guard let self else { return }
            if let d = self.saveDeadline, d > .now() {
                self.scheduleSaveCheckpoint()
                return
            }
            self.saveDeadline = nil
            self.saveScheduled = false
            self.performSaveNow()
        }
    }

    /// Write immediately — called when the canvas leaves the screen so an
    /// in-flight debounce can't drop the last edit.
    func flush() {
        saveDeadline = nil
        saveScheduled = false
        performSaveNow()
    }

    /// Snapshot the current document and post the disk write to the
    /// background queue. Shared by both the debounce path and `flush()`.
    private func performSaveNow() {
        let snapshot = elements
        let dir = directory
        let url = documentURL
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Undo

    /// Push the current document onto the undo stack. Call ONCE per user
    /// gesture, before the first mutation it makes — continuous gestures
    /// (drag-move, resize) snapshot at gesture start, not per frame.
    func snapshotUndo() {
        undoStack.append(elements)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = prev
        reconcileAfterHistoryJump()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        reconcileAfterHistoryJump()
    }

    private func reconcileAfterHistoryJump() {
        maxZ = elements.map(\.z).max() ?? 0
        if let sel = selectedID, !elements.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
        editingTextID = nil
        for el in elements where el.kind == .image {
            if let name = el.imageName, images[name] == nil {
                loadImage(named: name)
            }
        }
        save()
    }

    // MARK: Mutations

    func element(_ id: UUID) -> SephrNoteElement? {
        ensureIndex()
        guard let idx = _elementIndex?[id] else { return nil }
        return elements[idx]
    }

    /// Append with the next z. Caller is responsible for snapshotUndo().
    func add(_ element: SephrNoteElement) {
        var el = element
        maxZ += 1
        el.z = maxZ
        elements.append(el)
        save()
    }

    /// Replace in place by id (move/resize/text edits). No undo snapshot
    /// here — continuous gestures call this per frame.
    func update(_ element: SephrNoteElement) {
        guard let idx = elements.firstIndex(where: { $0.id == element.id })
        else { return }
        elements[idx] = element
        save()
    }

    func delete(_ id: UUID) {
        guard elements.contains(where: { $0.id == id }) else { return }
        snapshotUndo()
        elements.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        if editingTextID == id { editingTextID = nil }
        save()
    }

    func bringToFront(_ id: UUID) {
        guard let idx = elements.firstIndex(where: { $0.id == id }),
              elements[idx].z != maxZ else { return }
        maxZ += 1
        elements[idx].z = maxZ
        save()
    }

    /// Top-most element whose (slightly outset) frame contains `point` —
    /// the select tool's hit test. Walk the cached z-sorted list in
    /// reverse so we hit the topmost match and bail; no intermediate
    /// allocations per drag-begin / click.
    func topElement(at point: CGPoint) -> SephrNoteElement? {
        let sorted = elementsSortedByZ
        for el in sorted.reversed()
            where el.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return el
        }
        return nil
    }

    // MARK: Images

    /// Write `image` as a PNG asset and add an element centered on
    /// `center`, scaled down to fit comfortably in view.
    func addImage(_ image: NSImage, centeredAt center: CGPoint) {
        let name = "\(UUID().uuidString).png"
        let dir = directory
        let url = dir.appendingPathComponent(name)
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
        images[name] = image

        var size = image.size
        let maxSide: CGFloat = 480
        if size.width > maxSide || size.height > maxSide {
            let scale = maxSide / max(size.width, size.height)
            size = NSSize(width: size.width * scale,
                          height: size.height * scale)
        }
        size.width = max(size.width, 24)
        size.height = max(size.height, 24)

        snapshotUndo()
        add(SephrNoteElement(
            id: UUID(), kind: .image,
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height,
            points: nil, text: nil, fontSize: nil,
            imageName: name, z: 0))
    }

    func loadImage(named name: String) {
        guard images[name] == nil else { return }
        let url = directory.appendingPathComponent(name)
        Task.detached(priority: .utility) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self, let img else { return }
                self.images[name] = img
            }
        }
    }
}
