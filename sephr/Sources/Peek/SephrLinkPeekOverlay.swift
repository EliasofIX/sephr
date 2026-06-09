import AppKit
import CAL

/// Arc-style link "peek": a live, floating web view of a hovered link
/// rendered above the current page with a dimmed backdrop. Summoned by
/// Shift+hovering a link (see `SephrWindowController.installLinkPeekMonitor`).
///
/// Layout mirrors Arc's peek — a rounded, shadowed card centred over the
/// page area, with a vertical stack of controls floating in the dim margin
/// at the top-right:
///   • close  (×)            — dismiss the peek
///   • expand (↗↙)           — promote the link to a full tab
///   • split  (▭▯)           — open the link beside the current tab
///
/// The overlay is added as a full-bleed subview of the window's content
/// host, so the dim covers only the page area and the sidebar stays live.
final class SephrLinkPeekOverlay: NSView {

    var onClose: (() -> Void)?
    var onOpenAsTab: ((String) -> Void)?
    var onOpenInSplit: ((String) -> Void)?

    private let urlString: String
    /// Whether to show the "open as tab" / "open in split" promote controls.
    /// Off for adopted popups (OAuth/window.open): they're transient and
    /// re-opening by URL would lose the popup's opener relationship.
    private let showsPromoteControls: Bool
    private let backdrop = SephrPeekBackdrop()
    private let shadowHost = NSView()
    private let clip = NSView()
    private let webView: CALWebView
    private let controls = NSStackView()

    /// Inset of the floating card from the page area's edges. The right
    /// margin is wider so the control column has dim space to live in,
    /// matching the screenshot.
    private static let cardInsetTop: CGFloat = 40
    private static let cardInsetBottom: CGFloat = 40
    private static let cardInsetLeading: CGFloat = 56
    private static let cardInsetTrailing: CGFloat = 56
    private static let cardCornerRadius: CGFloat = 13

    /// Link peek — builds a fresh live web view of `urlString`
    /// (Shift+hover gesture). Shows the full promote control column.
    convenience init(urlString: String, profileID: String) {
        let url = URL(string: urlString) ?? URL(string: "about:blank")!
        self.init(webView: CALWebView(url: url, profile: profileID),
                  urlString: urlString,
                  showsPromoteControls: true)
    }

    /// Popup peek — hosts an already-live web view the bridge adopted from a
    /// window.open popup (OAuth/SSO sign-in). Close-only controls; it
    /// dismisses itself when the popup calls window.close().
    convenience init(adoptingPopup webView: CALWebView) {
        self.init(webView: webView,
                  urlString: webView.currentURL,
                  showsPromoteControls: false)
    }

    private init(webView: CALWebView,
                 urlString: String,
                 showsPromoteControls: Bool) {
        self.webView = webView
        self.urlString = urlString
        self.showsPromoteControls = showsPromoteControls
        super.init(frame: .zero)
        wantsLayer = true
        buildHierarchy()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Hierarchy

    private func buildHierarchy() {
        // 1. Dim backdrop — full bleed, clickable to dismiss.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onClick = { [weak self] in self?.onClose?() }
        addSubview(backdrop)

        // 2. Shadow host carries the drop shadow; it must NOT mask its
        //    bounds or the shadow is clipped away. The rounded clip view
        //    nested inside masks the live web view to the card's corners.
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.wantsLayer = true
        shadowHost.layer?.masksToBounds = false
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.40
        shadowHost.layer?.shadowRadius = 34
        shadowHost.layer?.shadowOffset = .zero
        addSubview(shadowHost)

        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cardCornerRadius
        clip.layer?.masksToBounds = true
        // Neutral fill so the card reads as a solid surface in the
        // moment between attach and the page's first paint.
        clip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shadowHost.addSubview(clip)

        webView.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(webView)

        // 3. Control column — floats in the top-right dim margin.
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .vertical
        controls.spacing = 10
        controls.wantsLayer = true
        let closeBtn = makeControl(symbol: "xmark",
                                   label: "Close peek",
                                   action: #selector(closeTapped))
        controls.addArrangedSubview(closeBtn)
        if showsPromoteControls {
            let expandBtn = makeControl(
                symbol: "arrow.up.left.and.arrow.down.right",
                label: "Open as tab",
                action: #selector(expandTapped))
            let splitBtn = makeControl(symbol: "rectangle.split.2x1",
                                       label: "Open in split",
                                       action: #selector(splitTapped))
            [expandBtn, splitBtn].forEach(controls.addArrangedSubview)
        }
        addSubview(controls)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            shadowHost.topAnchor.constraint(
                equalTo: topAnchor, constant: Self.cardInsetTop),
            shadowHost.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Self.cardInsetBottom),
            shadowHost.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.cardInsetLeading),
            shadowHost.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.cardInsetTrailing),

            clip.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            clip.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),

            webView.topAnchor.constraint(equalTo: clip.topAnchor),
            webView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            controls.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            controls.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -16),
        ])
    }

    override func layout() {
        super.layout()
        // Cache the shadow path so Core Animation doesn't rasterize a 34pt
        // blur every frame of the present/dismiss animation.
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: shadowHost.bounds,
            cornerWidth: Self.cardCornerRadius,
            cornerHeight: Self.cardCornerRadius,
            transform: nil)
    }

    // MARK: — Controls

    /// A circular Liquid Glass chip carrying a single SF Symbol. On macOS 26
    /// this is the real `NSGlassEffectView` with the button as its
    /// `contentView` (the canonical embed — the header warns arbitrary
    /// sibling subviews get no z-order/effect guarantees), using the
    /// `.clear` style for maximum transparency. Older systems fall back to a
    /// frosted `NSVisualEffectView` behind the button.
    private func makeControl(symbol: String,
                             label: String,
                             action: Selector) -> NSView {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol,
                          accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = .white
        b.toolTip = label
        b.target = self
        b.action = action

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.cornerRadius = 15
            glass.tintColor = nil
            glass.style = .clear           // most transparent glass variant
            glass.contentView = b          // canonical: embed in the glass
            NSLayoutConstraint.activate([
                glass.widthAnchor.constraint(equalToConstant: 30),
                glass.heightAnchor.constraint(equalToConstant: 30),
            ])
            return glass
        }

        // Pre-26 fallback: frosted material behind the button.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let v = NSVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.material = .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 15
        v.layer?.masksToBounds = true
        container.addSubview(v)
        container.addSubview(b)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 30),
            container.heightAnchor.constraint(equalToConstant: 30),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            b.topAnchor.constraint(equalTo: container.topAnchor),
            b.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            b.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            b.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    @objc private func closeTapped()  { onClose?() }
    @objc private func expandTapped() { onOpenAsTab?(urlString) }
    @objc private func splitTapped()  { onOpenInSplit?(urlString) }

    // MARK: — Present / dismiss animation
    //
    // A single CATransaction drives the dim fade and a small upward rise of
    // the card so opacity and transform share one timing curve (mixing
    // animator() with raw layer transforms desyncs them — see
    // SephrFloatingSidebar). Translation rather than scale keeps the motion
    // anchor-point independent, so the card never appears to grow from a
    // corner.
    private static let riseTranslation = CATransform3DMakeTranslation(0, 10, 0)

    func animateIn() {
        layoutSubtreeIfNeeded()
        guard let bg = backdrop.layer,
              let card = shadowHost.layer,
              let ctl = controls.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bg.opacity = 0
        card.opacity = 0
        card.transform = Self.riseTranslation
        ctl.opacity = 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut))
        bg.opacity = 1
        card.opacity = 1
        card.transform = CATransform3DIdentity
        ctl.opacity = 1
        CATransaction.commit()
    }

    func animateOut(completion: @escaping () -> Void) {
        guard let bg = backdrop.layer,
              let card = shadowHost.layer,
              let ctl = controls.layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock(completion)
        bg.opacity = 0
        card.opacity = 0
        card.transform = Self.riseTranslation
        ctl.opacity = 0
        CATransaction.commit()
    }
}

/// The dim layer behind the peek card. A bare NSView whose only jobs are to
/// darken the page (its layer background carries the tint) and to dismiss
/// the peek when the user clicks the dim margin. Clicks on the card itself
/// land on the live web view (a sibling drawn above this), never here.
private final class SephrPeekBackdrop: NSView {

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
