import XCTest
@testable import Sephr

final class PromptTrimmerTests: XCTestCase {

    func testParseSuperBrowseFindsNumberedSources() {
        let prompt = """
        QUESTION: What is Swift?

        [1] swift.org — Swift
        Line one

        Line two

        [2] apple.com — Apple
        Other body
        """
        let parts = PromptTrimmer.parseSuperBrowse(prompt)
        XCTAssertEqual(parts?.sources.count, 2)
        XCTAssertTrue(parts?.sources[0].contains("[1] swift.org") == true)
        XCTAssertTrue(parts?.sources[0].contains("Line two") == true)
        XCTAssertTrue(parts?.sources[1].hasPrefix("[2] apple.com") == true)
    }

    func testParseSuperBrowseReturnsNilForNonSuperBrowsePrompt() {
        XCTAssertNil(PromptTrimmer.parseSuperBrowse("PAGE: Title (host)\n\nBody"))
    }

    func testTrimSuperBrowseByCharCountDropsTrailingSources() {
        let body = String(repeating: "word ", count: 900)
        let prompt = """
        QUESTION: Q

        [1] a.example — A
        \(body)
        [2] b.example — B
        \(body)
        [3] c.example — C
        \(body)
        """
        let trimmed = PromptTrimmer.trimSuperBrowseByCharCount(
            prompt, maxChars: 4_000)
        XCTAssertNotNil(trimmed)
        XCTAssertFalse(trimmed?.contains("[3] c.example") == true)
        XCTAssertTrue(trimmed?.contains("[1] a.example") == true)
        XCTAssertFalse(trimmed?.contains("…") == true)
    }

    func testTrimSuperBrowseByCharCountReturnsNilWhenAlreadyFits() {
        let prompt = """
        QUESTION: Short

        [1] a.example — A
        Brief
        """
        XCTAssertNil(PromptTrimmer.trimSuperBrowseByCharCount(
            prompt, maxChars: 10_000))
    }

    func testPretrimForTokenizationPreservesDoubleNewlinesInKeptSources() {
        let body = String(repeating: "x", count: 5_000)
        let prompt = """
        QUESTION: Q

        [1] a.example — A
        alpha

        beta

        [2] b.example — B
        \(body)
        """
        let result = PromptTrimmer.pretrimForTokenization(
            prompt, maxChars: 3_000)
        XCTAssertTrue(result.contains("alpha\n\nbeta"))
        XCTAssertFalse(result.contains("[2] b.example"))
    }

    func testAssembleSuperBrowseRoundTripsParsedParts() {
        let prompt = "QUESTION: Q\n\n[1] host — Title\nBody\n"
        let parts = PromptTrimmer.parseSuperBrowse(prompt)
        XCTAssertEqual(PromptTrimmer.assembleSuperBrowse(parts!), prompt)
    }
}
