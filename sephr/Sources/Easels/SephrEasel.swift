import SwiftUI
import AppKit

/// Minimal Easel — a freeform canvas of screenshots and sticky notes.
/// Persistence: one JSON file per easel + PNG assets alongside it under
/// Application Support/Sephr/Easels/<id>/.
struct SephrEasel: View {

    @StateObject private var store = EaselStore()
    let easelID: UUID

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(NSColor.windowBackgroundColor)
                ForEach(store.items) { item in
                    EaselItemView(item: item, store: store)
                        .offset(x: item.x, y: item.y)
                        .onTapGesture {
                            store.bringToFront(item)
                        }
                }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, loc in
                store.handleDrop(providers: providers, at: loc)
                return true
            }
            .overlay(alignment: .topTrailing) {
                HStack {
                    Button { store.addStickyNote() } label: {
                        Image(systemName: "note.text.badge.plus")
                    }
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
        .onAppear { store.load(easelID: easelID) }
    }
}

struct EaselItem: Codable, Identifiable {
    let id: UUID
    var kind: String   // "image" | "note"
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var text: String?
    var imagePath: String?
    var z: Int
}

@MainActor
final class EaselStore: ObservableObject {
    @Published var items: [EaselItem] = []
    private(set) var easelID: UUID?
    /// Highest `z` seen so far. We previously walked the entire item
    /// list (`items.map(\.z).max()`) on every add / bring-to-front —
    /// O(n) per interaction. Tracking the running max collapses it to
    /// O(1) and avoids the transient allocation of the intermediate
    /// `[Int]` array.
    private var maxZ: Int = 0
    /// Trailing-edge debounce on the JSON write. Drag/resize from the
    /// item views ends up here too once we wire move + resize through;
    /// today only discrete actions call save() but they still benefit
    /// from coalescing across a rapid "add note → drag note → tweak"
    /// sequence.
    private var savePending: DispatchWorkItem?

    func load(easelID: UUID) {
        self.easelID = easelID
        let url = pathFor(easelID).appendingPathComponent("easel.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([EaselItem].self, from: data) {
            items = decoded
            maxZ = items.map(\.z).max() ?? 0
        }
    }

    /// Persist this easel. Coalesces to a single trailing write 250 ms
    /// after the last call. Encoding + disk write happen on a background
    /// queue so the main actor never blocks.
    func save() {
        guard let easelID else { return }
        savePending?.cancel()
        let snapshot = items
        let url = pathFor(easelID).appendingPathComponent("easel.json")
        let dir = pathFor(easelID)
        let work = DispatchWorkItem {
            Self.writeQueue.async {
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        savePending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.25, execute: work)
    }

    private static let writeQueue = DispatchQueue(
        label: "sephr.easel.write", qos: .utility)

    func addStickyNote() {
        maxZ += 1
        items.append(.init(id: UUID(), kind: "note",
                            x: 20, y: 20, width: 200, height: 120,
                            text: "", imagePath: nil,
                            z: maxZ))
        save()
    }

    func bringToFront(_ item: EaselItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        maxZ += 1
        items[idx].z = maxZ
        save()
    }

    func handleDrop(providers: [NSItemProvider], at loc: CGPoint) {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                Task { @MainActor in self.addImage(img, at: loc) }
            }
        }
    }

    private func addImage(_ image: NSImage, at loc: CGPoint) {
        guard let easelID else { return }
        let dir = pathFor(easelID)
        let imageName = "\(UUID().uuidString).png"
        let path = dir.appendingPathComponent(imageName)
        // PNG encode + disk write off the main actor; the @MainActor
        // assertion still holds because we only mutate `items` after the
        // hop back. Image is captured into the closure (NSImage is
        // immutable for our purposes once handed off here).
        let imageCopy = image
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            if let tiff = imageCopy.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: path)
            }
        }
        maxZ += 1
        items.append(.init(id: UUID(), kind: "image",
                            x: loc.x, y: loc.y,
                            width: image.size.width, height: image.size.height,
                            text: nil, imagePath: imageName,
                            z: maxZ))
        save()
    }

    func pathFor(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                  in: .userDomainMask)[0]
            .appendingPathComponent("Sephr/Easels/\(id.uuidString)")
    }
}

private struct EaselItemView: View {
    let item: EaselItem
    let store: EaselStore
    /// NSImage is loaded once via `.task` and cached for the lifetime
    /// of this view. The previous implementation called
    /// `NSImage(contentsOfFile:)` from `body`, which SwiftUI may
    /// re-invoke per frame during animation — each invocation re-read
    /// and re-decoded the PNG from disk.
    @State private var loadedImage: NSImage?

    var body: some View {
        Group {
            if item.kind == "note" {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.55))
                    .frame(width: item.width, height: item.height)
                    .overlay(
                        Text(item.text ?? "")
                            .padding(8)
                            .frame(maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading))
            } else if let img = loadedImage {
                Image(nsImage: img).resizable()
                    .frame(width: item.width, height: item.height)
                    .cornerRadius(6)
            } else {
                // Placeholder while the image decodes off the main thread.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: item.width, height: item.height)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .task(id: item.id) {
            guard item.kind == "image", loadedImage == nil,
                  let name = item.imagePath, let id = store.easelID else { return }
            // imagePath is just the basename; the file lives under
            // pathFor(easelID). Joining here means the previous
            // implementation's bug (passing a bare filename to
            // NSImage(contentsOfFile:)) is fixed as a side effect.
            let url = store.pathFor(id).appendingPathComponent(name)
            let img = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
            loadedImage = img
        }
    }
}
