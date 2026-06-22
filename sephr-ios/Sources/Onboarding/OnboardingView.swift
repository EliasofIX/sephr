import SwiftUI

/// First run: three quiet screens — the mark, what's different, the
/// default-browser ask — then straight into search. No account, no
/// friction.
struct OnboardingView: View {
    let onFinished: () -> Void

    @State private var page = 0
    @State private var spin: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            DC.Ink.field.ignoresSafeArea()

            // Explicit paging — buttons advance, nothing else can move
            // the page.
            Group {
                switch page {
                case 0:  welcome
                case 1:  features
                default: defaultBrowser
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: sizeClass == .regular ? 560 : .infinity)

            VStack {
                Spacer()
                pageDots
                    .padding(.bottom, DC.Space.m)
            }
        }
    }

    // MARK: — Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("✺")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(DC.Ink.ink)
                .rotationEffect(spin)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.spring(response: 1.6,
                                          dampingFraction: 0.8)) {
                        spin = .degrees(180)
                    }
                }

            Spacer().frame(height: DC.Space.huge)

            Text("BROWSER").dcLabel()
            Text("Sephr")
                .font(DC.TypeScale.display)
                .foregroundStyle(DC.Ink.ink)
            Text("The web, one thumb away.")
                .font(DC.TypeScale.callout)
                .foregroundStyle(DC.Ink.ink2)
                .padding(.top, DC.Space.s)

            Spacer()

            Button("Get Started") {
                advance(to: 1)
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .padding(.bottom, DC.Space.huge)
        }
        .padding(.horizontal, DC.Space.margin)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: DC.Space.huge)
            Text("HOW IT WORKS").dcLabel()
            Text("Less browser,\nmore web.")
                .font(DC.TypeScale.display)
                .foregroundStyle(DC.Ink.ink)
                .padding(.top, DC.Space.s)

            Spacer()

            VStack(spacing: DC.Space.m) {
                featureRow("magnifyingglass", "Search first",
                           "Open the app, start typing. The keyboard is "
                           + "already up.")
                featureRow("archivebox", "Tabs tidy themselves",
                           "Tabs you stop using slip into the archive on "
                           + "their own.")
                featureRow("bolt", "Fast by subtraction",
                           "Ads, trackers, and cookie banners are blocked "
                           + "before they load.")
            }

            Spacer()

            Button("Continue") {
                advance(to: 2)
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .padding(.bottom, DC.Space.huge)
        }
        .padding(.horizontal, DC.Space.margin)
    }

    private var defaultBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: DC.Space.huge)
            Text("ONE MORE THING").dcLabel()
            Text("Make it\nyour default.")
                .font(DC.TypeScale.display)
                .foregroundStyle(DC.Ink.ink)
                .padding(.top, DC.Space.s)
            Text("Links from other apps open in Sephr. You can change "
                 + "this anytime in Settings.")
                .font(DC.TypeScale.callout)
                .foregroundStyle(DC.Ink.ink2)
                .padding(.top, DC.Space.l)

            Spacer()

            VStack(spacing: DC.Space.m) {
                Button("Open Settings") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    onFinished()
                }
                .buttonStyle(DCPrimaryButtonStyle())

                Button("Skip") {
                    onFinished()
                }
                .buttonStyle(DCSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, DC.Space.huge)
        }
        .padding(.horizontal, DC.Space.margin)
    }

    // MARK: — Pieces

    private func featureRow(_ symbol: String, _ title: String,
                            _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DC.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DC.Ink.ink)
                .frame(width: 40, height: 40)
                .dcSurface()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DC.TypeScale.headline)
                    .foregroundStyle(DC.Ink.ink)
                Text(detail)
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DC.Space.l)
        .dcSurface()
    }

    private var pageDots: some View {
        HStack(spacing: DC.Space.s) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(i == page ? DC.Ink.ink : DC.Ink.ink4)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance(to next: Int) {
        withAnimation(reduceMotion ? nil
                      : .spring(response: 0.4, dampingFraction: 0.9)) {
            page = next
        }
    }
}
