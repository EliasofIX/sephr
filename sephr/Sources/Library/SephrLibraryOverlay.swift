import AppKit
import SwiftUI
import SephrKit

/// Full-window library overlay — slides in from the left over the main
/// browser chrome. Uses the same Liquid Glass backdrop as the normal
/// window frame. Dismiss by scrolling the Spaces board to the end and
/// overshooting toward the fixed exit strip, or via the rail back button.
final class SephrLibraryOverlay: NSView {

    var onDismiss: (() -> Void)?

    private let glassBackdrop: NSView
    private let rail = SephrLibraryRailView()
    private let contentHost = NSView()
    private var boardView: SephrManageSpacesBoardView?
    private var hostedSection: SephrLibrarySection?
    private var sectionHost: NSView?

    init(initialSection: SephrLibrarySection = .spaces) {
        glassBackdrop = Self.makeGlassBackdrop()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        showSection(initialSection, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: — Layout

    private static func makeGlassBackdrop() -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.cornerRadius = 0
            glass.tintColor = nil
            return glass
        }
        let v = NSVisualEffectView(frame: .zero)
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    private func buildLayout() {
        glassBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassBackdrop)

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.onSelect = { [weak self] section in
            self?.showSection(section, animated: true)
        }
        rail.onBack = { [weak self] in self?.requestDismiss() }
        addSubview(rail)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(contentHost)

        NSLayoutConstraint.activate([
            glassBackdrop.topAnchor.constraint(equalTo: topAnchor),
            glassBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: — Sections

    func showSection(_ section: SephrLibrarySection, animated: Bool) {
        guard section != hostedSection else {
            rail.setSelection(section)
            return
        }
        rail.setSelection(section)
        clearSectionHost()

        switch section {
        case .spaces:
            let board = SephrManageSpacesBoardView(frame: .zero)
            board.onRequestDismiss = { [weak self] in self?.requestDismiss() }
            board.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(board)
            NSLayoutConstraint.activate([
                board.topAnchor.constraint(equalTo: contentHost.topAnchor),
                board.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                board.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                board.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
            boardView = board
            sectionHost = board
        case .notes:
            mountSwiftUI(SephrLibraryNotesView(onOpenNote: { [weak self] id in
                self?.openNoteInBrowser(id)
            }))
        case .downloads:
            mountSwiftUI(SephrLibraryDownloadsView())
        case .archived:
            mountSwiftUI(SephrLibraryArchivedView(onRestore: { [weak self] tab in
                self?.openTabInBrowser(tab)
            }))
        }

        hostedSection = section
        if animated {
            sectionHost?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = SephrSidebarMotion.snappyCurve
                sectionHost?.animator().alphaValue = 1
            }
        }
    }

    private func mountSwiftUI<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentHost.topAnchor),
            host.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        sectionHost = host
        boardView = nil
    }

    private func clearSectionHost() {
        sectionHost?.removeFromSuperview()
        sectionHost = nil
        boardView = nil
    }

    // MARK: — Dismiss + motion

    func requestDismiss() {
        onDismiss?()
    }

    func slideIn() {
        guard let layer = layer else { return }
        let offset = CATransform3DMakeTranslation(-bounds.width, 0, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = offset
        layer.opacity = 1
        CATransaction.commit()

        if SephrSidebarMotion.reduceMotion {
            layer.transform = CATransform3DIdentity
            return
        }

        CATransaction.begin()
        layer.transform = CATransform3DIdentity

        let transform = SephrSidebarMotion.spring(keyPath: "transform", bounce: 0.10)
        transform.fromValue = NSValue(caTransform3D: offset)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(transform, forKey: "transform")
        CATransaction.commit()
    }

    /// Mirror of `slideIn` — the library arrived from the left, so it
    /// retreats back off the left when you scroll back to browsing.
    func slideOut(completion: @escaping () -> Void) {
        guard let layer = layer else { completion(); return }

        if SephrSidebarMotion.reduceMotion {
            completion()
            return
        }

        let offscreen = CATransform3DMakeTranslation(-bounds.width, 0, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.transform = offscreen

        let transform = SephrSidebarMotion.spring(keyPath: "transform", bounce: 0)
        transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        transform.toValue = NSValue(caTransform3D: offscreen)
        layer.add(transform, forKey: "transform")
        CATransaction.commit()
    }

    // MARK: — Hand off to browser

    private func openNoteInBrowser(_ id: UUID) {
        let tab: SephrTab
        if let existing = SephrTabModel.shared.tab(withID: id) {
            tab = existing
        } else {
            let title = SephrNoteRegistry.allNotes()
                .first(where: { $0.id == id })?.title ?? "Untitled Note"
            tab = SephrTabModel.shared.reopenNote(
                id: id, title: title,
                in: SephrSpaceManager.shared.currentSpace)
        }
        SephrTabModel.shared.activateTab(tab)
        requestDismiss()
    }

    private func openTabInBrowser(_ tab: SephrTab) {
        SephrTabModel.shared.activateTab(tab)
        requestDismiss()
    }
}
