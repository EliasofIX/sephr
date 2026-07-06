import AppKit
import SwiftUI
import CAL

/// Transparent click surface for download rows hosted inside NSPopovers.
/// SwiftUI `Button` + `.contextMenu` often miss the first click and never
/// show a menu in transient popovers; native mouse handling fixes both.
struct SephrDownloadRowClickSurface: NSViewRepresentable {
    let onClick: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> ClickSurface {
        let view = ClickSurface()
        view.onClick = onClick
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ view: ClickSurface, context: Context) {
        view.onClick = onClick
        view.menuProvider = menu
    }

    final class ClickSurface: NSView {
        var onClick: (() -> Void)?
        var menuProvider: (() -> NSMenu)?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                guard let menu = menuProvider?() else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
            guard event.buttonNumber == 0, event.clickCount == 1 else {
                super.mouseDown(with: event)
                return
            }
            onClick?()
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menuProvider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }
}

/// NSHostingController backed by a hosting view that accepts first mouse so
/// popover rows respond on the first click instead of only activating chrome.
final class SephrFirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        self.view = FirstMouseHostingView(rootView: rootView)
    }

    @MainActor @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum SephrDownloadMenuBuilder {

    @MainActor
    static func menu(for download: CALDownload) -> NSMenu {
        let menu = NSMenu()
        let obs = SephrDownloadsObserver.shared
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        let svc = CALDownloads.sharedInstance(forProfile: pid)

        switch download.state {
        case .complete:
            menu.addItem(item("Open") { obs.open(download) })
            menu.addItem(item("Show in Finder") { obs.revealInFinder(download) })
        case .inProgress:
            menu.addItem(item("Pause") { svc.pause(download.identifier) })
            menu.addItem(item("Cancel") { svc.cancel(download.identifier) })
        case .paused:
            menu.addItem(item("Resume") { svc.resume(download.identifier) })
            menu.addItem(item("Cancel") { svc.cancel(download.identifier) })
        case .canceled, .interrupted:
            break
        @unknown default:
            break
        }

        if !download.sourceURL.isEmpty {
            menu.addItem(item("Copy Link") { obs.copyLink(download) })
        }

        menu.addItem(.separator())
        menu.addItem(item("Remove from List") { obs.hide(download.identifier) })
        return menu
    }

    @MainActor
    private static func item(_ title: String,
                             enabled: Bool = true,
                             handler: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(handler: handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(ClosureTarget.invoke),
            keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        item.representedObject = target
        return item
    }
}

private final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}
