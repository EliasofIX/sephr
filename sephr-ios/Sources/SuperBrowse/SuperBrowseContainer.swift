import SwiftUI

/// Switches between the loading hero and the result page based on the
/// session phase. The transition is a cross-fade with a subtle scale —
/// the hero is upper-aligned, the result page is full-bleed, so they
/// don't share enough geometry for a matched-geometry handoff.
struct SuperBrowseContainer: View {
    @Environment(BrowserEngine.self) private var engine

    let session: SuperBrowseSession

    @State private var showResult = false

    var body: some View {
        ZStack {
            if showResult {
                SuperBrowseResultView(
                    session: session,
                    onDismiss: { engine.dismissSuperBrowse() },
                    onOpenInTab: { url in
                        engine.openInNewTab(url)
                    })
                    .transition(.opacity)
            } else {
                SuperBrowseHeroView(
                    session: session,
                    onCancel: { engine.dismissSuperBrowse() },
                    onResultReady: {
                        withAnimation(.spring(response: 0.35,
                                              dampingFraction: 0.9)) {
                            showResult = true
                        }
                    })
                    .transition(.opacity)
            }
        }
        .onChange(of: session.phase) { _, phase in
            // If we somehow already have an answer by the time we mount
            // (e.g. a really fast retry), skip the hero entirely.
            if case .done = phase, !showResult {
                withAnimation { showResult = true }
            }
            if case .error = phase {
                // Stay on the hero so the error message reads under the
                // query — easier to retry from there.
                showResult = false
            }
        }
    }
}
