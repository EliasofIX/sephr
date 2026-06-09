import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: SephrWindowController?
    private var updater: SephrUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = SephrWindowController()
        wc.showWindow(nil)
        mainWindowController = wc

        updater = SephrUpdater()
        updater?.automaticallyChecksForUpdates = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SephrSessionStore.shared.flush()
    }
}
