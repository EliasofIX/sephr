import SwiftUI

/// The rendered SuperBrowse answer page. Markdown is parsed inline into
/// DC-typeset SwiftUI blocks; citations are extracted from `[N]` markers
/// and surfaced as a tappable numbered source list at the foot.
struct SuperBrowseResultView: View {

    let session: SuperBrowseSession
    let onDismiss: () -> Void
    let onOpenInTab: (URL) -> Void

    var body: some View {
        ZStack {
            DC.Ink.field.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DC.Space.xl) {
                    header
                    answerBody
                    sourcesBlock
                    footerNote
                }
                .padding(.horizontal, DC.Space.margin)
                .padding(.top, DC.Space.xxl)
                .padding(.bottom, DC.Space.huge)
            }

            VStack {
                topBar
                Spacer()
            }
        }
    }

    // MARK: — Chrome

    private var topBar: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DC.Ink.ink)
                    .frame(width: 36, height: 36)
                    .dcGlass()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close SuperBrowse")
            Spacer()
            if case .generating = session.phase {
                Text("Writing…")
                    .dcLabel()
                    .dcLuminanceShimmer(active: true)
            }
        }
        .padding(.horizontal, DC.Space.l)
        .padding(.top, DC.Space.l)
    }

    // MARK: — Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DC.Space.s) {
            Text("SuperBrowse")
                .dcLabel()
            Text(session.question)
                .font(DC.TypeScale.title)
                .foregroundStyle(DC.Ink.ink)
        }
        .padding(.top, DC.Space.xxl)
    }

    // MARK: — Answer

    private var answerBody: some View {
        let blocks = MarkdownBlock.parse(session.answerMarkdown)
        return VStack(alignment: .leading, spacing: DC.Space.l) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if session.answerMarkdown.isEmpty,
               case .generating = session.phase {
                Text("…")
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink3)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text.uppercased())
                .font(DC.TypeScale.label)
                .tracking(1.6)
                .foregroundStyle(DC.Ink.ink3)
                .padding(.top, DC.Space.l)
        case .paragraph(let text):
            FormattedText(text: text)
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: DC.Space.m) {
                Text("·")
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink3)
                    .frame(width: 8, alignment: .leading)
                FormattedText(text: text)
                    .font(DC.TypeScale.body)
                    .foregroundStyle(DC.Ink.ink)
            }
        }
    }

    // MARK: — Sources

    private var sourcesBlock: some View {
        VStack(alignment: .leading, spacing: DC.Space.m) {
            Text("Sources")
                .dcLabel()
                .padding(.top, DC.Space.xl)

            ForEach(displayedSources, id: \.index) { entry in
                Button {
                    onOpenInTab(entry.source.url)
                    onDismiss()
                } label: {
                    HStack(alignment: .top, spacing: DC.Space.l) {
                        Text("\(entry.index)")
                            .font(DC.TypeScale.data)
                            .foregroundStyle(DC.Ink.ink3)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.source.title)
                                .font(DC.TypeScale.callout)
                                .foregroundStyle(DC.Ink.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(entry.source.host)
                                .font(DC.TypeScale.caption)
                                .foregroundStyle(DC.Ink.ink3)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(DC.Ink.ink4)
                    }
                    .padding(.vertical, DC.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(DC.Ink.hairline)
            }
        }
    }

    /// Surface cited sources first (in citation order), then any
    /// uncited ones the model collected, so the user sees the "real"
    /// references at the top.
    private var displayedSources: [(index: Int, source: SuperBrowseSource)] {
        var displayed: [(index: Int, source: SuperBrowseSource)] = []
        var seen = Set<Int>()
        for n in session.citedIndices {
            guard n >= 1, n <= session.sources.count,
                  !seen.contains(n) else { continue }
            displayed.append((n, session.sources[n - 1]))
            seen.insert(n)
        }
        for (i, source) in session.sources.enumerated() {
            let n = i + 1
            if !seen.contains(n) {
                displayed.append((n, source))
            }
        }
        return displayed
    }

    // MARK: — Footer

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ON-DEVICE")
                .dcLabel()
            Text("Answered locally by LFM2-VL-450M on this device. "
                 + "No prompts left your phone.")
                .font(DC.TypeScale.caption)
                .foregroundStyle(DC.Ink.ink3)
        }
        .padding(.top, DC.Space.xxl)
    }
}

// MARK: — Tiny block-level Markdown parser

/// SuperBrowse's prompt produces a tightly-shaped Markdown subset:
/// `## headings`, paragraphs, `- bullets` with `**bold**` inline. We parse
/// it line-by-line — no need for a general-purpose Markdown engine.
enum MarkdownBlock: Equatable {
    case heading(String)
    case paragraph(String)
    case bullet(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraphBuffer.removeAll()
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(
                    String(line.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(
                    String(line.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(
                    String(line.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)))
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}

/// Renders a piece of inline Markdown (bold + links) into a SwiftUI
/// `Text`. The `[N]` citation markers stay as plain text by design —
/// they're the reference number, not a visual ornament.
private struct FormattedText: View {
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
