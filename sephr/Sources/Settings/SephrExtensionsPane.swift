import SwiftUI
import AppKit
import CAL

/// Single source of truth for the installed-extension list, mirroring
/// `SephrDownloadsObserver`: owns the `CALExtensions.onExtensionsChanged`
/// subscription for the active profile and re-publishes it for SwiftUI.
/// Re-subscribes on space change so a profile switch reflects immediately.
/// Driven by the live `SephriumExtensions*` bridge into Chromium's
/// ExtensionRegistry / ExtensionRegistrar.
@MainActor
final class SephrExtensionsObserver: ObservableObject {

    static let shared = SephrExtensionsObserver()

    @Published private(set) var extensions: [CALExtension] = []

    private var currentProfileID: String?

    private init() {
        attachToCurrentProfile()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSpaceChanged),
            name: .sephrSpaceChanged, object: nil)
    }

    @objc private func onSpaceChanged() { attachToCurrentProfile() }

    private var profileID: String {
        currentProfileID ?? SephrSpaceManager.shared.currentSpace.profileID
    }

    private func attachToCurrentProfile() {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        guard pid != currentProfileID else { return }
        currentProfileID = pid
        let svc = CALExtensions.sharedInstance(forProfile: pid)
        svc.onExtensionsChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    func reload() {
        extensions = CALExtensions.sharedInstance(forProfile: profileID)
            .installed()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        CALExtensions.sharedInstance(forProfile: profileID)
            .setEnabled(id, enabled: on)
        reload()
    }

    func uninstall(_ id: String) {
        CALExtensions.sharedInstance(forProfile: profileID).uninstall(id)
        reload()
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
        .onAppear { obs.reload() }
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

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name)
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink)
                Text(ext.version)
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink3)
                    .monospacedDigit()
            }

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
                    .foregroundStyle(DC.Ink.ink2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(DC.Space.l)
        .dcGlass()
    }
}
