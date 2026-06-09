// Copyright (c) Sephr. All rights reserved.
// Phase 1 smoke harness — opens a single CALWebView in an NSWindow and prints
// navigation events. Standalone SPM exec so it doesn't depend on the rest of
// the Sephr Swift app.

import AppKit
import CAL

let argv = CommandLine.arguments
let urlString = argv.firstIndex(of: "--url").flatMap { i -> String? in
    i + 1 < argv.count ? argv[i + 1] : nil
} ?? "https://example.com"

guard let url = URL(string: urlString) else {
    FileHandle.standardError.write(Data("invalid --url: \(urlString)\n".utf8))
    exit(2)
}

CALEngineBootstrap.bootChromium()

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 1024, height: 768),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false)
window.title = "Sephr — CAL smoke test"

let webView = CALWebView(url: url, profile: "smoketest")
webView.frame = window.contentView?.bounds ?? .zero
webView.autoresizingMask = [NSView.AutoresizingMask.width,
                            NSView.AutoresizingMask.height]
window.contentView?.addSubview(webView)

webView.onNavigation = { url, title in
    print("Nav: \(url) / \(title)")
}

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
