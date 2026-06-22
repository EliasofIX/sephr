import AppKit

/// Presents the Arc-style library overlay inside the main browser window
/// instead of a separate Manage Spaces window.
@MainActor
final class SephrManageSpacesController {

    static let shared = SephrManageSpacesController()

    private init() {}

    /// Slide the library overlay in over the key window, starting on Spaces.
    func show() {
        present(section: .spaces)
    }

    func present(section: SephrLibrarySection = .spaces) {
        guard let wc = SephrApp.mainController ?? keyWindowController() else { return }
        wc.presentLibraryOverlay(section: section)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func keyWindowController() -> SephrWindowController? {
        (NSApp.keyWindow?.windowController as? SephrWindowController)
    }
}
