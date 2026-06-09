import AppKit

/// The horizontally-scrolling board of space columns inside the Manage
/// Spaces window. Tinted with the current space's accent so the whole
/// surface reads like Arc/Dia's manager (minus the left feature rail we
/// don't have). Rebuilds its columns when the space list, the current
/// space, or the tab model changes.
final class SephrManageSpacesBoardView: NSView {

    private let scrollView = NSScrollView()
    private let columnsStack = NSStackView()

    /// Debounce so a burst of `.sephrTabModelChanged` (favicon, title,
    /// loading flips while a page settles) doesn't rebuild the whole
    /// board on every notification.
    private var reloadPending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayout()
        refreshTint()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hardReload),
                       name: .sephrSpaceListChanged, object: nil)
        nc.addObserver(self, selector: #selector(onSpaceChanged),
                       name: .sephrSpaceChanged, object: nil)
        nc.addObserver(self, selector: #selector(softReload),
                       name: .sephrTabModelChanged, object: nil)

        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 24,
                                                bottom: 0, right: 24)

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        columnsStack.translatesAutoresizingMaskIntoConstraints = false
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 16
        columnsStack.distribution = .fill
        doc.addSubview(columnsStack)

        scrollView.documentView = doc
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

            columnsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            columnsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            columnsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            columnsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            // Fill the clip vertically and only scroll horizontally.
            doc.heightAnchor.constraint(
                equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    // MARK: — Tint

    private func refreshTint() {
        let tint = SephrSpaceManager.shared.currentSpace.color
        // Saturated wash over a near-black base — matches the manager's
        // full-bleed look without washing the columns out.
        layer?.backgroundColor = (tint.blended(withFraction: 0.62, of: .black)
                                  ?? .black).cgColor
    }

    // MARK: — Reload

    @objc private func hardReload() { refreshTint(); reload() }

    @objc private func onSpaceChanged() { refreshTint() }

    @objc private func softReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    private func reload() {
        columnsStack.arrangedSubviews.forEach {
            columnsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for space in SephrSpaceManager.shared.spaces {
            let column = SephrSpaceColumnView(space: space)
            columnsStack.addArrangedSubview(column)
            // Fill the board vertically — the stack's height tracks the
            // clip, so columns become full-height tiles like the reference.
            column.heightAnchor.constraint(
                equalTo: columnsStack.heightAnchor).isActive = true
        }
        // Trailing "add space" affordance, vertically centered like the
        // pink "+" in the reference.
        let addButton = SephrManageAddSpaceButton()
        addButton.onClick = { [weak self] in self?.createSpace() }
        let addWrap = NSView()
        addWrap.translatesAutoresizingMaskIntoConstraints = false
        addWrap.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.centerYAnchor.constraint(equalTo: addWrap.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: addWrap.leadingAnchor,
                                               constant: 8),
            addButton.trailingAnchor.constraint(equalTo: addWrap.trailingAnchor,
                                                constant: -8),
        ])
        columnsStack.addArrangedSubview(addWrap)
        addWrap.heightAnchor.constraint(
            equalTo: columnsStack.heightAnchor).isActive = true
    }

    private func createSpace() {
        _ = SephrSpaceManager.shared.createSpace(name: "New Space")
        // `createSpace` posts `.sephrSpaceListChanged`, which triggers
        // `hardReload()` and surfaces the new column.
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
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 22
        restAlpha = 0.14
        hoverAlpha = 0.24
        pressAlpha = 0.30
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
