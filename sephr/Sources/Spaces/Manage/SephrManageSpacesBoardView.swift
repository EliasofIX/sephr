import AppKit
import SephrKit

/// Horizontal scroll view for the spaces board. Converts vertical wheel
/// movement into horizontal scroll and only consumes the event when the
/// document is actually wider than the clip.
final class SephrManageSpacesScrollView: NSScrollView {

    override func scrollWheel(with event: NSEvent) {
        let docW = documentView?.frame.width ?? 0
        let clipW = contentView.bounds.width
        guard docW > clipW + 1 else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }

        let maxX = docW - clipW
        var origin = contentView.bounds.origin
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 12
        origin.x = max(0, min(maxX, origin.x + delta))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

/// The horizontally-scrolling board of space columns inside the library
/// overlay. A fixed exit strip is pinned to the window's trailing edge
/// (Arc-style); scroll the columns all the way right and overshoot to
/// dismiss back to browsing.
final class SephrManageSpacesBoardView: NSView {

    var onRequestDismiss: (() -> Void)?

    private let scrollView = SephrManageSpacesScrollView()
    private let columnsStack = NSStackView()
    private let exitStrip = SephrManageExitStrip()
    private let docView = NSView()

    private var reloadPending = false
    private var dismissTriggered = false
    private var structureToken: TabEventToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        buildLayout()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hardReload),
                       name: .sephrSpaceListChanged, object: nil)
        structureToken = TabEventBus.shared.subscribeStructure { [weak self] in
            self?.softReload()
        }

        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.syncDocumentSize() }
    }

    // MARK: — Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false

        // Frame-based document — Auto Layout document views get their
        // width pinned to the clip, which kills horizontal scrolling.
        docView.translatesAutoresizingMaskIntoConstraints = true

        columnsStack.translatesAutoresizingMaskIntoConstraints = false
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 16
        columnsStack.distribution = .gravityAreas
        docView.addSubview(columnsStack)

        scrollView.documentView = docView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        exitStrip.translatesAutoresizingMaskIntoConstraints = false
        exitStrip.onClick = { [weak self] in self?.triggerDismiss() }

        addSubview(scrollView)
        addSubview(exitStrip)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: exitStrip.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            exitStrip.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            exitStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            exitStrip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            exitStrip.widthAnchor.constraint(equalToConstant: SephrManageExitStrip.width),

            columnsStack.topAnchor.constraint(equalTo: docView.topAnchor),
            columnsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor,
                                                  constant: 20),
            columnsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        syncDocumentSize()
    }

    /// Size the scroll document from the column count × fixed width so
    /// many spaces always scroll instead of compressing.
    private func syncDocumentSize() {
        let clipH = scrollView.contentView.bounds.height
        let clipW = scrollView.contentView.bounds.width
        guard clipH > 0 else { return }

        columnsStack.layoutSubtreeIfNeeded()

        let itemCount = columnsStack.arrangedSubviews.count
        let spacing = columnsStack.spacing * CGFloat(max(0, itemCount - 1))
        let columnsWidth = CGFloat(SephrSpaceManager.shared.spaces.count)
            * SephrSpaceColumnView.columnWidth
        let addWidth: CGFloat = 60
        let insets: CGFloat = 32
        let contentWidth = columnsWidth + addWidth + spacing + insets
        let docW = max(contentWidth, clipW)

        docView.setFrameSize(NSSize(width: docW, height: clipH))
        docView.layoutSubtreeIfNeeded()
    }

    // MARK: — Reload

    @objc private func hardReload() { reload() }

    private func softReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    private func reload() {
        dismissTriggered = false
        columnsStack.arrangedSubviews.forEach {
            columnsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for space in SephrSpaceManager.shared.spaces {
            let column = SephrSpaceColumnView(space: space)
            column.setContentHuggingPriority(.required, for: .horizontal)
            column.setContentCompressionResistancePriority(.required, for: .horizontal)
            columnsStack.addArrangedSubview(column)
            column.heightAnchor.constraint(equalTo: columnsStack.heightAnchor).isActive = true
        }
        let addButton = SephrManageAddSpaceButton()
        addButton.onClick = { [weak self] in self?.createSpace() }
        let addWrap = NSView()
        addWrap.translatesAutoresizingMaskIntoConstraints = false
        addWrap.setContentHuggingPriority(.required, for: .horizontal)
        addWrap.setContentCompressionResistancePriority(.required, for: .horizontal)
        addWrap.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.centerYAnchor.constraint(equalTo: addWrap.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: addWrap.leadingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: addWrap.trailingAnchor, constant: -8),
            addWrap.widthAnchor.constraint(equalToConstant: 60),
        ])
        columnsStack.addArrangedSubview(addWrap)
        addWrap.heightAnchor.constraint(equalTo: columnsStack.heightAnchor).isActive = true
        syncDocumentSize()
    }

    // MARK: — Scroll-to-dismiss

    private var maxScrollX: CGFloat {
        let docW = scrollView.documentView?.frame.width ?? 0
        let clipW = scrollView.contentView.bounds.width
        return max(0, docW - clipW)
    }

    @objc private func scrollBoundsChanged() {
        guard onRequestDismiss != nil, !dismissTriggered else { return }
        let x = scrollView.contentView.bounds.origin.x
        if x > maxScrollX + 24 {
            triggerDismiss()
        }
    }

    private func triggerDismiss() {
        guard !dismissTriggered else { return }
        dismissTriggered = true
        onRequestDismiss?()
    }

    private func createSpace() {
        _ = SephrSpaceManager.shared.createSpace(name: "New Space")
    }
}

/// Fixed grey panel pinned to the window's trailing edge. Scroll the
/// space columns toward it, then overshoot to return to browsing.
final class SephrManageExitStrip: NSView {

    static let width: CGFloat = 148

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(0.06).cgColor
        updateTrackingAreas()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Round "+" button that adds a space at the end of the board.
final class SephrManageAddSpaceButton: SephrHoverButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "plus",
                        accessibilityDescription: "New Space")
        symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = DC.Radius.standard
        restAlpha = 0.08
        hoverAlpha = 0.14
        pressAlpha = 0.20
        target = self
        action = #selector(fire)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }
}
