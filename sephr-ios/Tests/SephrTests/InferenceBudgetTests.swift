import XCTest
@testable import Sephr

final class InferenceBudgetTests: XCTestCase {

    func testContextSizeReservesOutputHeadroom() {
        XCTAssertEqual(
            InferenceBudget.contextSize,
            InferenceBudget.softPromptTokenCeiling
                + InferenceBudget.maxOutputTokens)
    }

    func testSuperBrowseBudgetFitsEstimatedCharCeiling() {
        let total = InferenceBudget.superBrowseHeaderCharReserve
            + InferenceBudget.perSourceCharacterBudget
            * InferenceBudget.superBrowseSourceCount
        XCTAssertLessThanOrEqual(
            total, InferenceBudget.estimatedUserCharCeiling)
    }

    func testSummarizeBudgetMatchesEstimatedCeiling() {
        XCTAssertEqual(
            InferenceBudget.summarizePageCharacterBudget,
            InferenceBudget.estimatedUserCharCeiling)
    }
}
