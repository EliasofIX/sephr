import Foundation

/// Character-level text shaping for model prompts — no WebKit dependency so
/// unit tests can compile this module on any platform.
enum TextBudget {

    /// Collapse whitespace, dedupe paragraphs, and normalize Unicode so
    /// the same character budget carries fewer wasted tokens at prefill.
    static func normalizeForModel(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        var paragraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        paragraphs = paragraphs.filter { paragraph in
            let key = paragraph.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Cap a string at `n` characters at the last whitespace boundary,
    /// appending an ellipsis if it had to be cut.
    static func truncate(_ text: String, to n: Int) -> String {
        guard text.count > n else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: n)
        let head = text[..<endIndex]
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            return String(text[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }
}
