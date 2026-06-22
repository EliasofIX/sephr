import SwiftUI

/// The full-screen "Reading N pages…" hero shown from query submission
/// through model first-token. Replaces Arc's pink-purple gradient with a
/// strict DC monochrome treatment: the question in display weight, the
/// host list cascading down with a slow luminance shimmer.
struct SuperBrowseHeroView: View {

    let session: SuperBrowseSession
    let onCancel: () -> Void
    let onResultReady: () -> Void

    var body: some View {
        ZStack {
            DC.Ink.field.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DC.Space.huge) {
                header
                Spacer(minLength: 0)
                statusBlock
                Spacer(minLength: 0)
                cancelButton
            }
            .padding(.horizontal, DC.Space.margin)
            .padding(.vertical, DC.Space.xxl)
        }
        .onChange(of: session.phase) { _, phase in
            // Hand off to the result page the moment the model starts
            // streaming — the hero is for the wait, not for the read.
            if case .generating = phase { onResultReady() }
        }
    }

    // MARK: — Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DC.Space.s) {
            Text("SuperBrowse")
                .dcLabel()
            Text(session.question)
                .font(DC.TypeScale.display)
                .foregroundStyle(DC.Ink.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.65)
        }
    }

    // MARK: — Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: DC.Space.l) {
            Text(statusHeadline)
                .font(DC.TypeScale.title)
                .foregroundStyle(DC.Ink.ink)
                .dcLuminanceShimmer(active: isShimmerActive)

            if !session.hostsBeingRead.isEmpty {
                VStack(alignment: .leading, spacing: DC.Space.s) {
                    ForEach(Array(session.hostsBeingRead.enumerated()),
                            id: \.offset) { index, host in
                        Text(host)
                            .font(DC.TypeScale.headline)
                            .foregroundStyle(DC.Ink.ink3)
                            .opacity(hostOpacity(index: index))
                            .transition(.opacity)
                    }
                    if session.hostsBeingRead.count >= 6 {
                        Text("… and more")
                            .font(DC.TypeScale.callout)
                            .foregroundStyle(DC.Ink.ink4)
                    }
                }
                .animation(.easeInOut(duration: 0.4),
                           value: session.hostsBeingRead)
            }

            if case .error(let message) = session.phase {
                Text(message)
                    .font(DC.TypeScale.callout)
                    .foregroundStyle(DC.Ink.ink3)
                    .padding(.top, DC.Space.m)
            }
        }
    }

    private var statusHeadline: String {
        switch session.phase {
        case .fetchingSerp:
            return "Searching DuckDuckGo…"
        case .readingPages:
            let n = max(session.hostsBeingRead.count, 1)
            let read = session.sources.count
            return "Reading \(n) pages \(read > 0 ? "(\(read)/\(n))" : "")"
                .trimmingCharacters(in: .whitespaces)
        case .generating:
            return "Writing…"
        case .done:
            return "Done."
        case .cancelled:
            return "Cancelled."
        case .error:
            return "Couldn't finish that one."
        }
    }

    private var isShimmerActive: Bool {
        switch session.phase {
        case .fetchingSerp, .readingPages, .generating: return true
        default: return false
        }
    }

    /// Sources already extracted darken from `ink3` to `ink`; still-loading
    /// hosts stay quiet. Cheap progress signal without a spinner.
    private func hostOpacity(index: Int) -> Double {
        index < session.sources.count ? 1.0 : 0.55
    }

    // MARK: — Cancel

    private var cancelButton: some View {
        Button {
            onCancel()
        } label: {
            Text("Cancel")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DCSecondaryButtonStyle())
    }
}
