import AppKit
import CAL

/// Popover that shows a ~400×260 thumbnail of the hovered tab. Captures
/// once at show-time to avoid repeated GPU reads across hover sweeps.
final class SephrPeekPopover: NSPopover {

    private let tab: SephrTab
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")

    init(tab: SephrTab) {
        self.tab = tab
        super.init()
        behavior = .transient
        animates = true
        contentSize = NSSize(width: 400, height: 300)

        let vc = NSViewController()
        vc.view = buildContentView()
        contentViewController = vc
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.wantsLayer = true

        imageView.frame = NSRect(x: 12, y: 52, width: 376, height: 236)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = DC.Radius.standard
        imageView.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]

        titleLabel.frame = NSRect(x: 12, y: 28, width: 376, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.stringValue = tab.title
        titleLabel.lineBreakMode = .byTruncatingTail

        urlLabel.frame = NSRect(x: 12, y: 10, width: 376, height: 14)
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.stringValue = tab.url
        urlLabel.lineBreakMode = .byTruncatingTail

        [imageView, titleLabel, urlLabel].forEach { container.addSubview($0) }

        // Show the cached thumbnail immediately if we have one — most
        // tabs in the sidebar are inactive, their CALWebView is detached
        // from the host view, and their compositor is parked, so a live
        // CopyFromSurface would just hand back a blank surface. The
        // cached image is whatever was on the page the last time the
        // user navigated away from it (see
        // SephrWindowController.captureThumbnailForActiveTab).
        if let cached = tab.thumbnail {
            imageView.image = cached
        }

        // For the active tab (still attached, still rendering) take a
        // fresh capture — it'll overwrite the cached frame with the
        // most up-to-date pixels.
        if let wv = tab.webView, wv.window != nil {
            CALThumbnails.capture(from: wv,
                                   size: NSSize(width: 400, height: 250)) {
                [weak self] img in
                guard let self, let img else { return }
                self.imageView.image = img
                self.tab.thumbnail = img
            }
        }
        return container
    }
}
