import AppKit

final class SephrSplitViewController: NSSplitViewController {

    private let primary: SephrTab
    private let secondary: SephrTab

    /// Invoked when a pane's expand button is clicked: break the split and
    /// make that pane's tab the full active tab.
    var onExpand: ((SephrTab) -> Void)?

    init(primary: SephrTab, secondary: SephrTab) {
        self.primary = primary
        self.secondary = secondary
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Let NSSplitViewController build its default `view` + `splitView`
    // pair (the framework pins `splitView` to `view`'s edges for us).
    // Configuring a detached NSSplitView in loadView and assigning a bare
    // `self.view = NSView()` orphans the split view — it never enters the
    // hierarchy and the panes paint blank. viewDidLoad runs after the
    // default view is loaded, so `splitView` here is live and on-screen.
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let a = hostingItem(for: primary)
        let b = hostingItem(for: secondary)
        a.minimumThickness = 320
        b.minimumThickness = 320
        addSplitViewItem(a)
        addSplitViewItem(b)
    }

    private func hostingItem(for tab: SephrTab) -> NSSplitViewItem {
        let container = NSView()
        let wv = tab.getOrCreateWebView()
        wv.frame = container.bounds
        wv.autoresizingMask = [.width, .height]
        container.addSubview(wv)
        wv.unfreeze()

        // Liquid Glass expand button, top-left — added after the web view
        // so it z-orders above the page. Breaks the split and makes this
        // pane's tab full.
        let expand = SephrSplitExpandButton { [weak self] in
            self?.onExpand?(tab)
        }
        container.addSubview(expand)
        NSLayoutConstraint.activate([
            expand.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 12),
            expand.topAnchor.constraint(
                equalTo: container.topAnchor, constant: 12),
            expand.widthAnchor.constraint(equalToConstant: 28),
            expand.heightAnchor.constraint(equalToConstant: 28),
        ])

        let vc = NSViewController()
        vc.view = container
        return NSSplitViewItem(viewController: vc)
    }
}
