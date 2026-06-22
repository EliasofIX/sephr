import SwiftUI
import AppKit

/// The settings sections, presented as a centered Liquid Glass tab bar.
/// Each case is one pane; the icon is its SF Symbol. Tabs Sephr doesn't
/// have (Max, sync, gifts, Little Sephr) are deliberately absent.
enum SephrSettingsTab: String, CaseIterable, Hashable, Identifiable {
    case profile
    case general
    case tabs
    case privacy
    case extensions
    case links
    case icon
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile:    return "Profile"
        case .general:    return "General"
        case .tabs:       return "Tabs"
        case .privacy:    return "Privacy"
        case .extensions: return "Extensions"
        case .links:      return "Links"
        case .icon:       return "Icon"
        case .advanced:   return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .profile:    return "person.text.rectangle"
        case .general:    return "gearshape"
        case .tabs:       return "rectangle.stack"
        case .privacy:    return "lock.shield"
        case .extensions: return "puzzlepiece.extension"
        case .links:      return "eye"
        case .icon:       return "app.dashed"
        case .advanced:   return "slider.horizontal.3"
        }
    }

    static var barItems: [DCTabItem<SephrSettingsTab>] {
        allCases.map {
            DCTabItem(tab: $0, title: $0.title, systemImage: $0.systemImage)
        }
    }
}

/// Sephr's native settings screen — composed in the DIGITAL CAVIAR
/// language: a monochrome value ramp and glass rows over a behind-window
/// Liquid Glass field, with the chosen Memoji as the only colour. The
/// tabs float in a real Liquid Glass capsule (`DCTabBar`). Replaces the
/// Chromium `chrome://settings` page (and `chrome://extensions`) wholesale.
struct SephrSettingsView: View {

    @State private var selection: SephrSettingsTab = .profile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Liquid Glass field: behind-window blur, toned to the value
            // ramp's `field` so it reads light-on-light / dark-on-dark.
            VisualEffectBackground().ignoresSafeArea()
            DC.Ink.field.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 0) {
                // Centered section title in the draggable titlebar region.
                Text(selection.title)
                    .font(DC.TypeScale.label)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(DC.Ink.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, DC.Space.l)
                    .padding(.bottom, DC.Space.m)

                DCTabBar(items: SephrSettingsTab.barItems,
                         selection: $selection)
                    .padding(.horizontal, DC.Space.l)
                    .padding(.bottom, DC.Space.l)

                ScrollView {
                    VStack(alignment: .leading, spacing: DC.Space.xl) {
                        Color.clear.frame(height: DC.Space.s)
                        pane
                            // Asymmetric pane transition: new pane rises
                            // 6pt and fades in; old pane fades out flat.
                            // Without this the cross-fade was crisp but
                            // motionless — the eye never tracked the new
                            // content arriving. Keyed by `selection` so
                            // the .id flips identity on every tab change.
                            .id(selection)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .offset(y: 6)),
                                    removal: .opacity))
                        Color.clear.frame(height: DC.Space.huge)
                    }
                    .padding(.horizontal, DC.Space.margin)
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Scope the pane crossfade to the pane itself.
                    // Putting `.animation(value: selection)` on the
                    // whole ZStack made it catch every descendant that
                    // observed `selection` — including DCTabBar, whose
                    // own spring on `selection = item.tab` got clipped
                    // to this shorter easeInOut, and the entire titlebar
                    // row, which had no business crossfading.
                    .animation(reduceMotion ? nil : DC.Motion.easeOutPane,
                               value: selection)
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selection {
        case .profile:    ProfilePane()
        case .general:    GeneralPane()
        case .tabs:       TabsPane()
        case .privacy:    PrivacyPane()
        case .extensions: ExtensionsPane()
        case .links:      LinksPane()
        case .icon:       IconPane()
        case .advanced:   AdvancedPane()
        }
    }
}
