// Standalone test runner for Linux CI — keep in sync with SephrTests.
import Foundation

@inline(__always)
func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    guard condition else {
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
        exit(1)
    }
}

let body = String(repeating: "word ", count: 900)
let bigPrompt = """
QUESTION: Q

[1] a.example — A
\(body)
[2] b.example — B
\(body)
[3] c.example — C
\(body)
"""

expect(
    InferenceBudget.contextSize
        == InferenceBudget.softPromptTokenCeiling
        + InferenceBudget.maxOutputTokens,
    "contextSize must reserve output headroom")

let superBrowseTotal = InferenceBudget.superBrowseHeaderCharReserve
    + InferenceBudget.perSourceCharacterBudget
    * InferenceBudget.superBrowseSourceCount
expect(
    superBrowseTotal <= InferenceBudget.estimatedUserCharCeiling,
    "six SuperBrowse sources must fit the estimated char ceiling")

expect(
    InferenceBudget.summarizePageCharacterBudget
        == InferenceBudget.estimatedUserCharCeiling,
    "Summarize budget must match estimated ceiling")

let parts = PromptTrimmer.parseSuperBrowse(bigPrompt)
expect(parts?.sources.count == 3, "parseSuperBrowse finds three sources")

let trimmed = PromptTrimmer.trimSuperBrowseByCharCount(
    bigPrompt, maxChars: 4_000)
expect(trimmed != nil, "char trim drops trailing sources")
expect(trimmed?.contains("[3] c.example") == false, "source three removed")
expect(trimmed?.contains("…") == false, "char trim drops whole sources, not mid-body")

let shortPrompt = "QUESTION: Short\n\n[1] a.example — A\nBrief\n"
expect(
    PromptTrimmer.trimSuperBrowseByCharCount(shortPrompt, maxChars: 10_000) == nil,
    "no trim when already under budget")

let paragraphPrompt = """
QUESTION: Q

[1] a.example — A
alpha

beta

[2] b.example — B
\(String(repeating: "x", count: 5_000))
"""
let pretrimmed = PromptTrimmer.pretrimForTokenization(
    paragraphPrompt, maxChars: 3_000)
expect(pretrimmed.contains("alpha\n\nbeta"), "pretrim preserves paragraph breaks")
expect(!pretrimmed.contains("[2] b.example"), "pretrim drops trailing source")

let roundTrip = "QUESTION: Q\n\n[1] host — Title\nBody\n"
if let parsed = PromptTrimmer.parseSuperBrowse(roundTrip) {
    expect(
        PromptTrimmer.assembleSuperBrowse(parsed) == roundTrip,
        "assemble round-trips parse")
}

let truncated = TextBudget.truncate("one two three four five six", to: 15)
expect(truncated.hasSuffix("…"), "truncate adds ellipsis")
expect(!truncated.contains("six"), "truncate respects boundary")

expect(
    TextBudget.normalizeForModel("Hello\n\nhello\n\nWorld") == "Hello\n\nWorld",
    "normalize dedupes paragraphs")

fputs("OK: 12 assertions passed\n", stderr)
