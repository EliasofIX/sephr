import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CAL

/// Page-settings popover summoned from the URL bar's sliders button.
/// Mirrors the structure of Dia's page popover but wires only actions
/// Sephr can actually perform today: share, screenshot, developer
/// tools, extension management, and a jump to full Settings. Monochrome
/// via the shared DC tokens.
///
/// The view is intentionally "dumb" about tabs — the host URL field
/// passes in the page URL and closures for the actions that need the
/// live CALWebView, so this file never reaches into the tab model.
struct SephrPageSettingsPanel: View {

    let url: String
    let onScreenshot: () -> Void
    let onDevTools: () -> Void
    let onOpenSettings: () -> Void

    @AppStorage("developer.mode") private var developerMode = false
    @StateObject private var extensions: SephrExtensionsModel

    init(url: String,
         profileID: String,
         onScreenshot: @escaping () -> Void,
         onDevTools: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.url = url
        self.onScreenshot = onScreenshot
        self.onDevTools = onDevTools
        self.onOpenSettings = onOpenSettings
        _extensions = StateObject(
            wrappedValue: SephrExtensionsModel(profileID: profileID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DC.Space.l) {
            actionRow
            extensionsSection
            settingsSection
            Divider().overlay(DC.Ink.hairline)
            bottomRow
        }
        .padding(DC.Space.l)
        .frame(width: 300)
    }

    // MARK: — Top action row (Share · Screenshot · Dev Tools)

    private var actionRow: some View {
        HStack(spacing: DC.Space.s) {
            if let shareURL = URL(string: url) {
                ShareLink(item: shareURL) {
                    PageActionLabel(symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            Button(action: onScreenshot) {
                PageActionLabel(symbol: "camera")
            }
            .buttonStyle(.plain)
            // Developer Tools is gated behind Developer Mode so the
            // toggle below has a visible, immediate effect.
            if developerMode {
                Button(action: onDevTools) {
                    PageActionLabel(symbol: "curlybraces")
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: — Extensions

    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: DC.Space.m) {
            HStack {
                Text("Extensions").dcLabel()
                Spacer()
                Button(action: addExtension) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DC.Ink.ink2)
                        .frame(width: 22, height: 22)
                        .background(DC.Ink.surface,
                                    in: RoundedRectangle(cornerRadius: 7,
                                                         style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if extensions.items.isEmpty {
                Text("No extensions installed")
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink3)
            } else {
                VStack(spacing: DC.Space.s) {
                    ForEach(extensions.items, id: \.extensionID) { ext in
                        ExtensionRow(ext: ext) { on in
                            extensions.setEnabled(ext.extensionID, on)
                        }
                    }
                }
            }
        }
    }

    // MARK: — Settings (Developer Mode)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: DC.Space.m) {
            Text("Settings").dcLabel()
            Toggle("Developer Mode", isOn: $developerMode)
                .toggleStyle(DCToggleStyle())
        }
    }

    // MARK: — Bottom row (Secure indicator · more)

    private var bottomRow: some View {
        HStack {
            HStack(spacing: DC.Space.s) {
                Image(systemName: isSecure ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isSecure ? "Secure" : "Not Secure")
                    .font(DC.TypeScale.caption)
            }
            .foregroundStyle(DC.Ink.ink2)
            .padding(.horizontal, DC.Space.m)
            .padding(.vertical, DC.Space.s)
            .background(DC.Ink.surface, in: Capsule(style: .continuous))

            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DC.Ink.ink2)
                    .frame(width: 30, height: 30)
                    .background(DC.Ink.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var isSecure: Bool { url.lowercased().hasPrefix("https://") }

    // MARK: — Extension install

    private func addExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let crx = UTType(filenameExtension: "crx") {
            panel.allowedContentTypes = [crx]
        }
        panel.allowsOtherFileTypes = true
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        extensions.install(path: file.path)
    }
}

// MARK: — Reusable action button label

/// Square glass action button matching Image #2's top row.
private struct PageActionLabel: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(DC.Ink.ink)
            .frame(width: 46, height: 38)
            .background(DC.Ink.surface,
                        in: RoundedRectangle(cornerRadius: 10,
                                             style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DC.Ink.hairline,
                                  lineWidth: DC.hairlineWidth))
    }
}

// MARK: — Extension row

private struct ExtensionRow: View {
    let ext: CALExtension
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { ext.isEnabled }, set: onToggle)) {
            HStack(spacing: DC.Space.s) {
                icon
                Text(ext.name).lineLimit(1)
            }
        }
        .toggleStyle(DCToggleStyle())
    }

    @ViewBuilder private var icon: some View {
        if let image = ext.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14))
                .foregroundStyle(DC.Ink.ink2)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: — Extensions data model

/// Thin ObservableObject wrapper over the profile-scoped `CALExtensions`
/// store. Mutations and the change callback all land on the main thread,
/// matching how the rest of Sephr's chrome touches CAL.
final class SephrExtensionsModel: ObservableObject {

    @Published var items: [CALExtension] = []
    private let store: CALExtensions

    init(profileID: String) {
        store = CALExtensions.sharedInstance(forProfile: profileID)
        items = store.installed()
        store.onExtensionsChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = self.store.installed()
            }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        store.setEnabled(id, enabled: on)
        items = store.installed()
    }

    func install(path: String) {
        do {
            try store.installCRX(atPath: path)
            items = store.installed()
        } catch {
            NSSound.beep()
        }
    }
}
