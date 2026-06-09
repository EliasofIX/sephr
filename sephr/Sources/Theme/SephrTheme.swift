import AppKit

struct SephrTheme: Codable, Equatable {
    var name: String
    var mode: Mode
    var sidebarTintHex: String?
    var contentWallpaperPath: String?

    enum Mode: String, Codable { case light, dark, system }

    static let defaultLight = SephrTheme(
        name: "Default Light", mode: .light,
        sidebarTintHex: nil, contentWallpaperPath: nil)

    static let defaultDark = SephrTheme(
        name: "Default Dark", mode: .dark,
        sidebarTintHex: nil, contentWallpaperPath: nil)
}
