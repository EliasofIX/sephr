import AppKit
import CAL

/// Little Sephr — a borderless floating panel with a single CALWebView.
/// Used for quick-reference browsing without disturbing the current space.
final class LittleSephrWindow {

    private static var panel: NSPanel?
    private static var webView: CALWebView?

    static func show(url: String = "https://search.brave.com") {
        if let panel = panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let rect = NSRect(x: 0, y: 0, width: 520, height: 640)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView,
                        .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Little Sephr"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let wv = CALWebView(url: URL(string: url)!, profile: "default")
        wv.autoresizingMask = [NSView.AutoresizingMask.width,
                               NSView.AutoresizingMask.height]
        panel.contentView = wv
        panel.makeKeyAndOrderFront(nil)

        webView = wv
        Self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
        webView = nil
    }
}
