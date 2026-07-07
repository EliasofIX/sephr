import Foundation

/// Shared inference limits for SuperBrowse, Summarize, and LEAP loading.
/// Keep prompt trimming, extraction budgets, and `contextSize` in sync here.
enum InferenceBudget {

    /// Input-token ceiling before the 450M model loses coherence.
    static let softPromptTokenCeiling = 8_192

    /// Max completion tokens per answer (`GenerationOptions.maxTokens`).
    static let maxOutputTokens = 2_048

    /// LEAP KV slot — prompt ceiling plus room for the completion stream.
    static let contextSize = softPromptTokenCeiling + maxOutputTokens

    /// SuperBrowse reads this many SERP results.
    static let superBrowseSourceCount = 6

    /// Headroom for `QUESTION:` plus `[N] host — title` headers.
    static let superBrowseHeaderCharReserve = 2_000

    /// ~3.5 chars per token (35 / 10), used before native tokenization.
    private static let charsPerTokenNumerator = 35
    private static let charsPerTokenDenominator = 10

    /// Rough user-turn char ceiling from the soft token budget.
    static var estimatedUserCharCeiling: Int {
        let roughTokens = max(512, softPromptTokenCeiling - 256)
        return max(
            512,
            roughTokens * charsPerTokenNumerator / charsPerTokenDenominator)
    }

    /// Per-source extraction cap for SuperBrowse fan-out.
    static var perSourceCharacterBudget: Int {
        let bodyBudget = max(
            512, estimatedUserCharCeiling - superBrowseHeaderCharReserve)
        return max(512, bodyBudget / superBrowseSourceCount)
    }

    /// Single-page Summarize cap — trimmed again before tokenization.
    static var summarizePageCharacterBudget: Int {
        estimatedUserCharCeiling
    }

    static func estimatedCharBudget(forTokenBudget tokens: Int) -> Int {
        max(256, tokens * charsPerTokenNumerator / charsPerTokenDenominator)
    }
}
