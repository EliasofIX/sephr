import SwiftUI
import AppKit
import CAL

/// Single source of truth for the installed-extension list, mirroring
/// `SephrDownloadsObserver`: registers a `CALExtensions` change observer for
/// the active profile and re-publishes the list for SwiftUI.
/// Re-subscribes on space change so a profile switch reflects immediately.
/// Driven by the live `SephriumExtensions*` bridge into Chromium's
/// ExtensionRegistry / ExtensionRegistrar.
@MainActor
final class SephrExtensionsObserver: ObservableObject {

    static let shared = SephrExtensionsObserver()

    @Published private(set) var extensions: [CALExtension] = []

    private var currentProfileID: String?
    private var observedService: CALExtensions?
    private var observerToken: Any?

    private init() {
        attachToCurrentProfile()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSpaceChanged),
            name: .sephrSpaceChanged, object: nil)
        // No didBecomeActive belt-and-suspenders: the live change observer
        // registered via `addChangeObserver` already covers extension
        // installs from a tab, even when the app is backgrounded — the
        // observer fires on the next runloop turn after the extension
        // registrar updates. Re-reading every activation just hammered
        // the CAL bridge on every Cmd-Tab into the app.
    }

    @objc private func onSpaceChanged() { attachToCurrentProfile() }

    private var profileID: String {
        currentProfileID ?? SephrSpaceManager.shared.currentSpace.profileID
    }

    private func attachToCurrentProfile() {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        guard pid != currentProfileID else { return }
        currentProfileID = pid
        // Drop the previous profile's observer before re-registering.
        if let observedService, let observerToken {
            observedService.removeChangeObserver(observerToken)
        }
        let svc = CALExtensions.sharedInstance(forProfile: pid)
        observedService = svc
        observerToken = svc.addChangeObserver { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    func reload() {
        extensions = CALExtensions.sharedInstance(forProfile: profileID)
            .installed()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        // The bridge's live change observer (set up in attachToCurrentProfile)
        // already pushes a reload() on the next runloop turn after this lands —
        // the synchronous reload was hitting CAL twice per toggle.
        CALExtensions.sharedInstance(forProfile: profileID)
            .setEnabled(id, enabled: on)
    }

    func uninstall(_ id: String) {
        // Same story — observer fires reload() after the uninstall completes.
        CALExtensions.sharedInstance(forProfile: profileID).uninstall(id)
    }
}

// MARK: — Pane

/// Native replacement for `chrome://extensions`, in the DIGITAL CAVIAR
/// language. Lists installed extensions live from the engine with per-row
/// enable / remove, and links out to the Web Store inside Sephr to add more.
struct ExtensionsPane: View {
    @StateObject private var obs = SephrExtensionsObserver.shared

    private let webStore = "https://chromewebstore.google.com/"

    var body: some View {
        VStack(spacing: DC.Space.xl) {
            DCSection(title: "INSTALLED") {
                if obs.extensions.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: DC.Space.m) {
                        ForEach(obs.extensions, id: \.extensionID) { ext in
                            ExtensionRow(ext: ext, observer: obs)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    let space = SephrSpaceManager.shared.currentSpace
                    SephrTabModel.shared.newTab(in: space, url: webStore)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Get Extensions", systemImage: "arrow.up.right")
                }
                .buttonStyle(DCPrimaryButtonStyle())
            }
        }
        // No .onAppear reload — the SephrExtensionsObserver singleton's live
        // CAL change observer + space-change re-attach are already the
        // source of truth. A pane open used to fire a third reload() on top.
    }

    private var emptyState: some View {
        VStack(spacing: DC.Space.m) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(DC.Ink.ink3)
            Text("No extensions installed")
                .font(DC.TypeScale.headline)
                .foregroundStyle(DC.Ink.ink)
            Text("Add extensions from the Web Store and they'll show up here.")
                .font(DC.TypeScale.caption)
                .foregroundStyle(DC.Ink.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DC.Space.xl)
        .padding(.horizontal, DC.Space.l)
        .dcGlass()
    }
}

/// One installed extension: icon, name, version, an enable toggle, and an
/// overflow menu for removal.
private struct ExtensionRow: View {
    let ext: CALExtension
    let observer: SephrExtensionsObserver

    @State private var enabled: Bool
    @State private var rowHovering = false
    @State private var menuHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(ext: CALExtension, observer: SephrExtensionsObserver) {
        self.ext = ext
        self.observer = observer
        _enabled = State(initialValue: ext.isEnabled)
    }

    var body: some View {
        HStack(spacing: DC.Space.l) {
            Group {
                if let icon = ext.icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(DC.Ink.ink3)
                        .padding(6)
                }
            }
            .frame(width: 30, height: 30)
            // Disabled extensions read as dimmed so the row's status is
            // legible at a glance — the toggle was the only existing cue.
            .opacity(enabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name)
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink)
                Text(ext.version)
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink3)
                    .monospacedDigit()
            }
            .opacity(enabled ? 1 : 0.55)

            Spacer(minLength: DC.Space.s)

            Toggle("", isOn: $enabled)
                .toggleStyle(DCToggleStyle())
                .labelsHidden()
                .onChange(of: enabled) { _, v in
                    observer.setEnabled(ext.extensionID, v)
                }

            Menu {
                Button("Remove", role: .destructive) {
                    observer.uninstall(ext.extensionID)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(menuHovering ? DC.Ink.ink : DC.Ink.ink2)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(menuHovering
                                  ? DC.Ink.hairline : Color.clear))
                    .scaleEffect(menuHovering ? 1.06 : 1)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { menuHovering = $0 }
            .animation(reduceMotion ? nil : DC.Motion.hover,
                       value: menuHovering)
        }
        .padding(DC.Space.l)
        .dcGlass()
        // Subtle hover lift on the whole row so the active extension
        // separates from siblings. Stroke brightens on hover too,
        // riding on top of the dcGlass hairline.
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(DC.Ink.hairline,
                              lineWidth: rowHovering
                                ? DC.hairlineWidth * 2
                                : 0)
                .opacity(rowHovering ? 1 : 0)
                .allowsHitTesting(false))
        .scaleEffect(rowHovering ? 1.004 : 1)
        .onHover { rowHovering = $0 }
        .animation(reduceMotion ? nil : DC.Motion.hover, value: rowHovering)
    }
}
