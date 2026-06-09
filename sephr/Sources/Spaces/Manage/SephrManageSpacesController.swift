import AppKit

/// Owns the "Manage Spaces" window — an Arc-style board of space columns
/// you can reorder by dragging, with tabs and folders draggable between
/// them. Lazily created, single-instance; reuses the transparent
/// full-bleed chrome the settings window uses.
@MainActor
final class SephrManageSpacesController: NSObject, NSWindowDelegate {

    static let shared = SephrManageSpacesController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// Bring the board window forward, creating it lazily.
    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let board = SephrManageSpacesBoardView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 680))

        let w = NSWindow(
            contentRect: board.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        w.contentView = board
        w.title = "Manage Spaces"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 760, height: 460)
        w.center()
        w.delegate = self
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
