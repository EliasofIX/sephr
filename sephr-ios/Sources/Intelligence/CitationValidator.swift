import Foundation

/// Post-validates the LLM's `[N]` citation markers against the source list.
///
/// At 450M parameters the model will sometimes cite [7] when only 6 sources
/// exist, or drop citations entirely. We never edit the model's prose —
/// we just collect which sources it actually used, drop unknown indices,
/// and let the renderer surface a "no citations" note when the answer is
/// ungrounded.
enum CitationValidator {

    /// Indices the model actually referenced, in first-appearance order,
    /// clamped to the source set.
    static func citedIndices(in markdown: String,
                             sourceCount: Int) -> [Int] {
        var seen = Set<Int>()
        var order: [Int] = []
        // Match `[N]` where N is 1-3 digits. Allow runs `[1][3]`.
        let pattern = #/\[(\d{1,3})\]/#
        for match in markdown.matches(of: pattern) {
            guard let n = Int(match.output.1),
                  n >= 1, n <= sourceCount,
                  !seen.contains(n) else { continue }
            seen.insert(n)
            order.append(n)
        }
        return order
    }

    /// True when the answer is the explicit "I don't know" fallback we
    /// taught the model to emit.
    static func isExplicitNoAnswer(_ markdown: String) -> Bool {
        let trimmed = markdown.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return trimmed.localizedCaseInsensitiveContains(
            "couldn't find a confident answer")
            || trimmed.localizedCaseInsensitiveContains(
                "nothing to summarize")
    }
}
