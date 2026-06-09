import SwiftUI
import AppKit

/// The individual settings panes behind each tab in `SephrSettingsView`.
/// Each is a self-contained `View` reading and writing `SephrPreferences`
/// directly, composed from the DIGITAL CAVIAR row/section primitives.

// MARK: — Profile

/// Identity card, Arc-style: a generated gradient "portrait" (the one
/// sanctioned splash of colour), the display name, and a swatch picker —
/// the placeholder for Arc's little profile images. No account, email,
/// sync, or gifts; Sephr has none of those.
struct ProfilePane: View {
    @State private var name = SephrPreferences.profileDisplayName
    @State private var avatar = SephrPreferences.profileAvatarSeed

    private var resolvedName: String {
        if !name.isEmpty { return name }
        let full = NSFullUserName()
        return full.isEmpty ? "Your Name" : full
    }

    /// Arc's "tombstone" portrait: a tall dome — large top radii, slight
    /// bottom radii. Built from `UnevenRoundedRectangle` (no custom Shape).
    private var arch: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 96, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 96,
            style: .continuous)
    }

    var body: some View {
        VStack(spacing: DC.Space.xl) {
            // Portrait card
            VStack(spacing: DC.Space.l) {
                DCGradientAvatar(seed: avatar)
                    .frame(width: 196, height: 232)
                    .clipShape(arch)
                    .overlay(arch.stroke(DC.Ink.hairline,
                                         lineWidth: DC.hairlineWidth))

                VStack(spacing: DC.Space.xs) {
                    Text(resolvedName)
                        .font(DC.TypeScale.title)
                        .foregroundStyle(DC.Ink.ink)
                        .tracking(-0.2)
                    Text("SEPHR EXPLORER").dcLabel()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DC.Space.xl)
            .dcGlass(cornerRadius: 24)

            // Swatch picker — the little profile images.
            DCSection(title: "PROFILE IMAGE") {
                HStack(spacing: DC.Space.m) {
                    ForEach(0..<6, id: \.self) { i in
                        Button {
                            avatar = i
                            SephrPreferences.profileAvatarSeed = i
                        } label: {
                            DCGradientAvatar(seed: i)
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().strokeBorder(
                                        avatar == i ? DC.Ink.ink
                                                    : DC.Ink.hairline,
                                        lineWidth: avatar == i ? 2
                                                   : DC.hairlineWidth))
                        }
                        .buttonStyle(.plain)
                        .help("Profile swatch \(i + 1)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(DC.Space.l)
                .dcGlass()
            }

            // Display name
            DCSection(title: "DISPLAY NAME") {
                DCRow("Name",
                      subtitle: "Shown on your profile card.") {
                    TextField(NSFullUserName(), text: $name)
                        .textFieldStyle(DCTextFieldStyle())
                        .frame(maxWidth: 220)
                        .onChange(of: name) { _, v in
                            SephrPreferences.profileDisplayName = v
                        }
                }
            }
        }
    }
}

// MARK: — General

struct GeneralPane: View {
    @State private var engine: SephrSearchEngine = SephrSearchEngines.current
    @State private var customURL = SephrPreferences.customSearchURL
    @State private var mode = SephrPreferences.themeMode
    @State private var compactSidebar = SephrPreferences.sidebarCompact
    @State private var confirmOnQuit = SephrPreferences.confirmOnQuit
    @State private var autoCheck = true
    @State private var isDefaultBrowser = SephrDefaultBrowser.shared.isDefault

    var body: some View {
        VStack(spacing: DC.Space.xl) {
            DCSection(title: "DEFAULT BROWSER") {
                DCRow("Use Sephr for web links",
                      subtitle: isDefaultBrowser
                          ? "Sephr opens http and https links from other apps."
                          : "Make Sephr the system default so links open here.") {
                    if isDefaultBrowser {
                        Label("Default", systemImage: "checkmark.seal.fill")
                            .font(DC.TypeScale.body)
                            .foregroundStyle(DC.Ink.ink)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Set as Default") {
                            SephrDefaultBrowser.shared.setAsDefault { _ in
                                isDefaultBrowser =
                                    SephrDefaultBrowser.shared.isDefault
                            }
                        }
                        .buttonStyle(DCSecondaryButtonStyle())
                    }
                }
            }

            DCSection(title: "SEARCH") {
                DCRow("Search engine",
                      subtitle: "Queries from the address bar route "
                              + "through this engine.") {
                    Picker("", selection: $engine) {
                        ForEach(SephrSearchEngine.allCases) { e in
                            Text(e.displayName).tag(e)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(DC.Ink.ink)
                    .onChange(of: engine) { _, v in
                        SephrPreferences.searchEngineID = v.rawValue
                    }
                }

                if engine == .custom {
                    DCRow("Custom URL",
                          subtitle: "The encoded query is appended to "
                                  + "this prefix verbatim.") {
                        TextField("https://example.com/search?q=",
                                  text: $customURL)
                            .textFieldStyle(DCTextFieldStyle())
                            .frame(maxWidth: 280)
                            .onChange(of: customURL) { _, v in
                                SephrPreferences.customSearchURL = v
                            }
                    }
                }
            }

            DCSection(title: "APPEARANCE") {
                DCRow("Theme",
                      subtitle: "Light / dark is value-relative; hue "
                              + "never enters.") {
                    Picker("", selection: $mode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(DC.Ink.ink)
                    .onChange(of: mode) { _, v in
                        SephrPreferences.themeMode = v
                        let tm = SephrTheme.Mode(rawValue: v) ?? .system
                        SephrThemeEngine.shared.apply(SephrTheme(
                            name: "Custom", mode: tm,
                            sidebarTintHex: nil, contentWallpaperPath: nil))
                    }
                }

                DCRow("Compact sidebar by default",
                      subtitle: "Open in 52pt strip mode instead of full "
                              + "width.") {
                    Toggle("", isOn: $compactSidebar)
                        .toggleStyle(DCToggleStyle())
                        .labelsHidden()
                        .onChange(of: compactSidebar) { _, v in
                            SephrPreferences.sidebarCompact = v
                        }
                }
            }

            DCSection(title: "GENERAL") {
                DCRow("Confirm before quitting",
                      subtitle: "Cmd+Q asks before closing — like Dia.") {
                    Toggle("", isOn: $confirmOnQuit)
                        .toggleStyle(DCToggleStyle())
                        .labelsHidden()
                        .onChange(of: confirmOnQuit) { _, v in
                            SephrPreferences.confirmOnQuit = v
                        }
                }

                DCRow("Automatically check for updates",
                      subtitle: "Quietly probe the feed on launch.") {
                    Toggle("", isOn: $autoCheck)
                        .toggleStyle(DCToggleStyle())
                        .labelsHidden()
                        .onChange(of: autoCheck) { _, v in
                            SephrApp.updater?
                                .automaticallyChecksForUpdates = v
                        }
                }
            }

            HStack {
                Spacer()
                Button("Check for Updates") {
                    SephrApp.updater?.checkNow()
                }
                .buttonStyle(DCPrimaryButtonStyle())
            }
        }
        .onAppear {
            autoCheck = SephrApp.updater?
                .automaticallyChecksForUpdates ?? false
            isDefaultBrowser = SephrDefaultBrowser.shared.isDefault
        }
    }
}

// MARK: — Tabs

struct TabsPane: View {
    @State private var archiveDays = SephrPreferences.archiveAfterDays
    @State private var suspendSeconds = SephrPreferences.suspendAfterSeconds

    var body: some View {
        DCSection(title: "LIFECYCLE") {
            DCRow("Archive after",
                  subtitle: "Idle tabs move to the archive after this "
                          + "window.") {
                HStack(spacing: DC.Space.m) {
                    Text("\(archiveDays) days")
                        .font(DC.TypeScale.data)
                        .foregroundStyle(DC.Ink.ink)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                    Stepper("", value: $archiveDays, in: 1...60)
                        .labelsHidden()
                        .onChange(of: archiveDays) { _, v in
                            SephrPreferences.archiveAfterDays = v
                        }
                }
            }

            DCRow("Suspend after",
                  subtitle: "Inactive renderers freeze to save memory.") {
                HStack(spacing: DC.Space.m) {
                    Text("\(suspendSeconds) s")
                        .font(DC.TypeScale.data)
                        .foregroundStyle(DC.Ink.ink)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                    Stepper("", value: $suspendSeconds, in: 30...3600,
                            step: 30)
                        .labelsHidden()
                        .onChange(of: suspendSeconds) { _, v in
                            SephrPreferences.suspendAfterSeconds = v
                        }
                }
            }
        }
    }
}

// MARK: — Privacy

struct PrivacyPane: View {
    @State private var blockAds = SephrPreferences.blockAds
    @State private var blockTrackers = SephrPreferences.blockTrackers

    var body: some View {
        DCSection(title: "CONTENT BLOCKING") {
            DCRow("Block ads",
                  subtitle: "EasyList rules applied at the network "
                          + "layer.") {
                Toggle("", isOn: $blockAds)
                    .toggleStyle(DCToggleStyle())
                    .labelsHidden()
                    .onChange(of: blockAds) { _, v in
                        SephrPreferences.blockAds = v
                    }
            }

            DCRow("Block trackers",
                  subtitle: "EasyPrivacy rules applied alongside ad "
                          + "blocking.") {
                Toggle("", isOn: $blockTrackers)
                    .toggleStyle(DCToggleStyle())
                    .labelsHidden()
                    .onChange(of: blockTrackers) { _, v in
                        SephrPreferences.blockTrackers = v
                    }
            }
        }
    }
}

// MARK: — Links (Peek)

/// Peek previews a link without opening a new tab. Little Sephr is
/// intentionally omitted for now.
struct LinksPane: View {
    @State private var shiftClick = SephrPreferences.peekOnShiftClick
    @State private var external = SephrPreferences.peekOnExternalLinks
    @State private var archiveHours = SephrPreferences.peekArchiveHours

    private let archiveOptions = [1, 3, 6, 12, 24]

    var body: some View {
        VStack(spacing: DC.Space.xl) {
            Text("Peek previews a link without opening a new tab — "
               + "perfect for a quick look at a link from an email, "
               + "article, or message.")
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            DCSection(title: "PEEK") {
                DCRow("Open a Peek on Shift-click",
                      subtitle: "Hold Shift while clicking a link to "
                              + "preview it.") {
                    Toggle("", isOn: $shiftClick)
                        .toggleStyle(DCToggleStyle())
                        .labelsHidden()
                        .onChange(of: shiftClick) { _, v in
                            SephrPreferences.peekOnShiftClick = v
                        }
                }

                DCRow("Peek links to other sites",
                      subtitle: "Only affects Favorites and Pinned "
                              + "tabs.") {
                    Toggle("", isOn: $external)
                        .toggleStyle(DCToggleStyle())
                        .labelsHidden()
                        .onChange(of: external) { _, v in
                            SephrPreferences.peekOnExternalLinks = v
                        }
                }

                DCRow("Archive Peeks after",
                      subtitle: "Idle Peek windows close after this.") {
                    Picker("", selection: $archiveHours) {
                        ForEach(archiveOptions, id: \.self) { h in
                            Text(h == 6 ? "6 hours (default)"
                                        : "\(h) hours").tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(DC.Ink.ink)
                    .onChange(of: archiveHours) { _, v in
                        SephrPreferences.peekArchiveHours = v
                    }
                }
            }
        }
    }
}

// MARK: — Icon

/// App-icon picker. Only the shipping icon is real today; the rest are
/// locked placeholders, built now so the surface is ready when more land.
struct IconPane: View {
    @State private var selected = SephrPreferences.appIconIndex

    private let columns = [GridItem(.adaptive(minimum: 88),
                                    spacing: DC.Space.l)]

    var body: some View {
        VStack(spacing: DC.Space.xl) {
            Text("Choose how Sephr appears in your Dock and app "
               + "switcher. More icons are on the way.")
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            DCSection(title: "APP ICON") {
                LazyVGrid(columns: columns, spacing: DC.Space.l) {
                    tile(index: 0, locked: false)
                    ForEach(1..<5, id: \.self) { i in
                        tile(index: i, locked: true)
                    }
                }
                .padding(DC.Space.l)
                .dcGlass()
            }
        }
    }

    @ViewBuilder
    private func tile(index: Int, locked: Bool) -> some View {
        let isSelected = selected == index && !locked
        Button {
            guard !locked else { return }
            selected = index
            SephrPreferences.appIconIndex = index
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DC.Ink.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16,
                                         style: .continuous)
                            .strokeBorder(
                                isSelected ? DC.Ink.ink : DC.Ink.hairline,
                                lineWidth: isSelected ? 2
                                           : DC.hairlineWidth))

                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(DC.Ink.ink4)
                } else if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(DC.Space.m)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(DC.Ink.ink2)
                }
            }
            .frame(width: 88, height: 88)
            .opacity(locked ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? "Coming soon" : "Default")
    }
}

// MARK: — Advanced

/// Intentionally sparse — Sephr genuinely has no sound effects, haptics,
/// boosts, or the other Arc toggles, so they're absent rather than faked.
/// What remains is the diagnostic "about" data.
struct AdvancedPane: View {
    var body: some View {
        DCSection(title: "ABOUT") {
            DCRow("Version", subtitle: nil) {
                Text(Self.versionString)
                    .font(DC.TypeScale.data)
                    .foregroundStyle(DC.Ink.ink2)
            }
            DCRow("Chromium engine", subtitle: nil) {
                Text(Self.chromiumVersion)
                    .font(DC.TypeScale.data)
                    .foregroundStyle(DC.Ink.ink2)
            }
        }
    }

    /// Computed once, cached as a static. Both strings are
    /// process-lifetime constants — Bundle keys don't change at runtime.
    private static let versionString: String = {
        let v = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        let b = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }()

    private static let chromiumVersion: String = {
        if let url = Bundle.main.builtInPlugInsURL ??
                     Bundle.main.privateFrameworksURL,
           let plist = NSDictionary(contentsOf: url
                .appendingPathComponent("Sephr Framework.framework")
                .appendingPathComponent("Versions/A/Resources/Info.plist")),
           let v = plist["CFBundleShortVersionString"] as? String {
            return v
        }
        return "Sephrium 147"
    }()
}
