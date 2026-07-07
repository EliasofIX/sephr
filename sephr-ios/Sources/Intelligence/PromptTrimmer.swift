import Foundation

/// Pure prompt-shaping helpers for SuperBrowse user turns. Extracted so
/// `InferenceWorker` and unit tests share the same trimming rules.
enum PromptTrimmer {

    struct SuperBrowseParts: Equatable {
        let header: String
        let sources: [String]
    }

    private static let sourceHeaderPattern = #"(?m)^\[\d+\] "#

    static func parseSuperBrowse(_ prompt: String) -> SuperBrowseParts? {
        guard prompt.contains("QUESTION:") else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: sourceHeaderPattern) else { return nil }
        let ns = prompt as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: prompt, options: [], range: fullRange)
        guard !matches.isEmpty else { return nil }

        let header = ns.substring(to: matches[0].range.location)
        let sources = matches.enumerated().map { index, match in
            let start = match.range.location
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            return ns.substring(with: NSRange(
                location: start, length: end - start))
        }
        return SuperBrowseParts(header: header, sources: sources)
    }

    static func assembleSuperBrowse(_ parts: SuperBrowseParts) -> String {
        parts.header + parts.sources.joined()
    }

    /// Drop trailing numbered sources until the prompt fits `maxChars`.
    /// Returns nil when no sources were removed.
    static func trimSuperBrowseByCharCount(
        _ prompt: String,
        maxChars: Int
    ) -> String? {
        guard prompt.count > maxChars,
              let parts = parseSuperBrowse(prompt) else { return nil }
        var kept = parts.sources
        let initialCount = kept.count
        while kept.count > 1,
              parts.header.count + kept.map(\.count).reduce(0, +) > maxChars {
            kept.removeLast()
        }
        guard kept.count < initialCount else { return nil }
        return parts.header + kept.joined()
    }

    /// Drop trailing sources while `overBudget` is true. Preserves exact
    /// source substrings from the original prompt. Returns nil when no
    /// sources were removed.
    static func trimSuperBrowseSources(
        in prompt: String,
        overBudget: (String) async throws -> Bool
    ) async throws -> String? {
        guard let parts = parseSuperBrowse(prompt) else { return nil }
        guard parts.sources.count > 1 else { return nil }
        var kept = parts.sources
        let initialCount = kept.count
        while kept.count > 1 {
            let candidate = parts.header + kept.joined()
            if try await overBudget(candidate) {
                kept.removeLast()
            } else {
                break
            }
        }
        guard kept.count < initialCount else { return nil }
        return parts.header + kept.joined()
    }

    /// Shrink toward `maxChars`, dropping whole SuperBrowse sources before
    /// blind tail truncation.
    static func pretrimForTokenization(
        _ prompt: String,
        maxChars: Int
    ) -> String {
        if prompt.count <= maxChars { return prompt }
        if let trimmed = trimSuperBrowseByCharCount(prompt, maxChars: maxChars) {
            if trimmed.count <= maxChars { return trimmed }
            return TextBudget.truncate(trimmed, to: maxChars)
        }
        return TextBudget.truncate(prompt, to: maxChars)
    }
}
