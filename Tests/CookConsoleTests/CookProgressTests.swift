import XCTest

@testable import CookConsole

final class CookProgressTests: XCTestCase {
    func testNextAndBackMoveOneStepAndStayWithinRecipeBounds() throws {
        var progress = try CookProgress(stepCount: 3, currentStepIndex: 0)

        XCTAssertFalse(progress.moveBack())
        XCTAssertTrue(progress.moveNext())
        XCTAssertEqual(progress.currentStepIndex, 1)
        XCTAssertTrue(progress.moveNext())
        XCTAssertEqual(progress.currentStepIndex, 2)
        XCTAssertFalse(progress.moveNext())
        XCTAssertEqual(progress.currentStepIndex, 2)
        XCTAssertTrue(progress.moveBack())
        XCTAssertEqual(progress.currentStepIndex, 1)
    }
}
