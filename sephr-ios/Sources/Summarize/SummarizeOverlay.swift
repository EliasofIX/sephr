import SwiftUI

/// Full-screen overlay shown during and after the origami fold. The
/// snapshot folds into a thin strip at top; the summary card rises from
/// below, filling the rest.
struct SummarizeOverlay: View {

    let session: SummarizeSession
    let onDismiss: () -> Void
    let onExpandBack: () -> Void

    @State private var foldProgress: Double = 0
    @State private var summaryReveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Final folded strip height — the bit of the page we keep visible
    /// at top after the fold.
    private var stripHeightFraction: CGFloat { 0.18 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                DC.Ink.field.ignoresSafeArea()

                // 1. Folded page snapshot — pinned to the top.
                Button(action: onExpandBack) {
                    OrigamiFoldView(snapshot: session.snapshot,
                                    progress: foldProgress)
                }
                .buttonStyle(.plain)
                .frame(height: proxy.size.height)
                .accessibilityLabel("Show original page")

                // 2. Summary card — rises from below, filling the
                // bottom (1 - strip) of the screen once the fold settles.
                summaryCard
                    .frame(height: proxy.size.height
                        * (1 - stripHeightFraction))
                    .offset(y: proxy.size.height
                        * (stripHeightFraction
                           + (1 - summaryReveal) * 0.05))
                    .opacity(summaryReveal)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .onAppear {
                triggerHaptic()
                if reduceMotion {
                    foldProgress = 1; summaryReveal = 1
                    return
                }
                withAnimation(.spring(response: 0.55,
                                      dampingFraction: 0.86)) {
                    foldProgress = 1
                }
                withAnimation(.easeOut(duration: 0.35).delay(0.20)) {
                    summaryReveal = 1
                }
            }
        }
    }

    // MARK: — Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: DC.Space.l) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DC.Space.l) {
                    summaryBody
                    footerNote
                }
                .padding(.horizontal, DC.Space.margin)
                .padding(.bottom, DC.Space.huge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DC.Ink.field)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DC.Ink.hairline)
                .frame(height: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summary")
                    .dcLabel()
                Text(session.pageTitle)
                    .font(DC.TypeScale.headline)
                    .foregroundStyle(DC.Ink.ink)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DC.Ink.ink)
                    .frame(width: 32, height: 32)
                    .dcSurface()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close summary")
        }
        .padding(.horizontal, DC.Space.margin)
        .padding(.top, DC.Space.l)
    }

    @ViewBuilder
    private var summaryBody: some View {
        switch session.phase {
        case .folding, .generating:
            VStack(alignment: .leading, spacing: DC.Space.m) {
                renderedSummary
                Text("Writing…")
                    .dcLabel()
                    .dcLuminanceShimmer(active: true)
                    .padding(.top, DC.Space.s)
            }
        case .done:
            renderedSummary
        case .cancelled:
            Text("Summary cancelled.")
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink3)
        case .error(let message):
            Text(message)
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink3)
        }
    }

    private var renderedSummary: some View {
        let blocks = MarkdownBlock.parse(session.summaryMarkdown)
        return VStack(alignment: .leading, spacing: DC.Space.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline,
                           spacing: DC.Space.m) {
                        Text("·")
                            .font(DC.TypeScale.body)
                            .foregroundStyle(DC.Ink.ink3)
                            .frame(width: 8, alignment: .leading)
                        SummarizeText(text: text)
                            .font(DC.TypeScale.body)
                            .foregroundStyle(DC.Ink.ink)
                    }
                case .paragraph(let text):
                    SummarizeText(text: text)
                        .font(DC.TypeScale.body)
                        .foregroundStyle(DC.Ink.ink)
                case .heading(let text):
                    Text(text)
                        .font(DC.TypeScale.headline)
                        .foregroundStyle(DC.Ink.ink)
                        .padding(.top, DC.Space.s)
                }
            }
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ON-DEVICE")
                .dcLabel()
            Text("Summarized locally by LFM2-VL-450M. The page text "
                 + "stayed on this device.")
                .font(DC.TypeScale.caption)
                .foregroundStyle(DC.Ink.ink3)
        }
        .padding(.top, DC.Space.l)
    }

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.7)
    }
}

/// Inline-Markdown rendering for summary bullets — bold lead-in,
/// remainder regular. Same renderer as SuperBrowse, scoped narrower.
private struct SummarizeText: View {
    let text: String
    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
