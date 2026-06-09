import AppKit

@MainActor
final class SephrSpaceThemeEngine {
    static let shared = SephrSpaceThemeEngine()
    private init() {}

    private(set) var currentTint: NSColor = .systemIndigo

    func apply(_ space: SephrSpace) {
        currentTint = space.color
        NSApp.windows.forEach { window in
            if let vibrancy = window.contentView?.subviews
                .compactMap({ $0 as? NSVisualEffectView }).first {
                vibrancy.layer?.compositingFilter = nil
                vibrancy.layer?.backgroundColor = space.color
                    .withAlphaComponent(0.05).cgColor
            }
        }
        NotificationCenter.default.post(name: .sephrThemeChanged, object: space)
    }
}
