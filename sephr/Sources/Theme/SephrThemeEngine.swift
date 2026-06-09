import AppKit

@MainActor
final class SephrThemeEngine {
    static let shared = SephrThemeEngine()
    private init() { applySavedMode() }

    func apply(_ theme: SephrTheme) {
        switch theme.mode {
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        SephrPreferences.themeMode = theme.mode.rawValue
    }

    private func applySavedMode() {
        let raw = SephrPreferences.themeMode
        let mode = SephrTheme.Mode(rawValue: raw) ?? .system
        switch mode {
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}
