import Foundation

/// System prompts and per-source formatting for SuperBrowse + Summarize.
///
/// LFM2-VL-450M is a tiny instruct model. The hard lessons from real
/// runs on device:
///
/// • Long, English-paragraph system prompts make it copy the input
///   back. The system prompt has to be SHORT and DECLARATIVE.
/// • The model needs hard caps on input — beyond ~8 K input tokens it
///   loses coherence and starts echoing.
/// • "Exactly four headings", "between three and five bullets" — the
///   model can't count. Give a range, accept whatever it produces.
/// • The ALL-CAPS section headers (VOICE / STRUCTURE / CITATIONS) read
///   to the model as labels it should write back. Drop them.
enum Prompts {

    // MARK: — SuperBrowse

    /// Terse, declarative system turn. Less for the model to misinterpret.
    static let superBrowseSystem = """
    You answer the user's QUESTION using only the SOURCES below. \
    Do not use outside knowledge. Cite every claim with [N] where N is \
    the source number. Write four to seven Markdown bullets. Each bullet \
    is: "- **Two-word lead.** One short fact-led sentence [N]." \
    If the sources do not answer the question, reply with only: \
    "I couldn't find a confident answer in the available sources."
    """

    /// User turn: question + numbered sources, fenced with terse
    /// delimiters so a small model can keep them straight.
    static func superBrowseUserPrompt(
        question: String,
        sources: [SuperBrowseSource]
    ) -> String {
        var output = "QUESTION: \(question)\n\n"
        for (index, source) in sources.enumerated() {
            let n = index + 1
            output += "\n[\(n)] \(source.host) — \(source.title)\n"
            output += source.markdown
            output += "\n"
        }
        return output
    }

    // MARK: — Summarize

    static let summarizeSystem = """
    Summarize the PAGE TEXT below in four to seven Markdown bullets. \
    Each bullet is: "- **Two-word lead.** One short fact-led sentence." \
    Use only what the page says. Do NOT quote the page verbatim — \
    rewrite. If the page is empty or unreadable, reply with only: \
    "Nothing to summarize on this page."
    """

    static func summarizeUserPrompt(
        pageTitle: String,
        host: String,
        bodyText: String
    ) -> String {
        "PAGE: \(pageTitle) (\(host))\n\n\(bodyText)"
    }
}

/// One scraped source for SuperBrowse — populated by `ReaderExtractor`,
/// consumed by `Prompts.superBrowseUserPrompt`.
struct SuperBrowseSource: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
    let host: String
    let markdown: String   // already truncated to per-source budget
}
