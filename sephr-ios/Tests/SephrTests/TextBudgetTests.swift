import XCTest
@testable import Sephr

final class TextBudgetTests: XCTestCase {

    func testTruncateRespectsWhitespaceBoundary() {
        let text = "one two three four five six"
        let result = TextBudget.truncate(text, to: 15)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertFalse(result.contains("six"))
    }

    func testNormalizeForModelDedupesParagraphs() {
        let input = "Hello\n\nhello\n\nWorld"
        XCTAssertEqual(TextBudget.normalizeForModel(input), "Hello\n\nWorld")
    }
}
