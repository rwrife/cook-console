import XCTest

/// Issue #6 UI coverage: the in-app "Your data" screen — the single place
/// the user owns their data (JSON/CSV export through the system share
/// sheet, validated JSON import, and the written privacy statement).
/// The export path here exercises the real store end to end: button ->
/// AppStore -> DataTransferService -> on-device file -> share item.
final class DataOwnershipUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
    }

    func testYourDataScreenExportsBackupWithProvenanceAndStatesPrivacy() {
        // The toolbar entry exists in both the empty and populated states.
        let yourData = app.buttons["Your data"]
        XCTAssertTrue(yourData.waitForExistence(timeout: 5), app.debugDescription)
        yourData.tap()

        // The written privacy statement (acceptance criterion: documented
        // on-device storage + zero-network behavior in the app itself).
        // Queried by explicit identifiers — section headers render uppercased
        // and text matching would be case-fragile. Scroll until realized:
        // List rows below the fold are lazily mounted in the AX tree.
        scrollToExists(app.staticTexts["Privacy storage statement"])
        XCTAssertTrue(
            app.staticTexts["Privacy storage statement"].label.contains("zero network requests"),
            app.staticTexts["Privacy storage statement"].label
        )
        scrollToExists(app.staticTexts["Privacy permissions statement"])
        XCTAssertTrue(app.staticTexts["Privacy permissions statement"].exists)
        scrollToExists(app.staticTexts["Privacy deletion statement"])
        XCTAssertTrue(
            app.staticTexts["Privacy deletion statement"].label
                .contains("Deleting the app deletes everything"),
            app.staticTexts["Privacy deletion statement"].label
        )

        // No import has run yet: no stale summary may linger.
        XCTAssertFalse(app.staticTexts["Import summary"].exists)

        // One-tap JSON backup: write, confirm, and a share item appears.
        scrollToExists(app.buttons["Export JSON backup"])
        app.buttons["Export JSON backup"].tap()
        XCTAssertTrue(
            app.alerts["Export ready"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(
            app.buttons["Share JSON backup"].waitForExistence(timeout: 5),
            app.debugDescription
        )

        // CSV history export the same way.
        scrollToExists(app.buttons["Export CSV history"])
        app.buttons["Export CSV history"].tap()
        XCTAssertTrue(
            app.alerts["Export ready"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(
            app.buttons["Share CSV history"].waitForExistence(timeout: 5),
            app.debugDescription
        )

        // The import entry point is present (its file picker is a system
        // surface; validation/merge behavior is unit-tested in
        // DataTransferServiceTests against the real GRDB store).
        scrollToExists(app.buttons["Import JSON backup"])
        XCTAssertTrue(app.buttons["Import JSON backup"].exists)
    }

    /// Hosted-simulator List rows mount lazily; probe, then scroll down,
    /// then back up, bounded, until the element realizes in the AX tree.
    /// iOS 26 SwiftUI List bridges to UICollectionView (run 35616324431
    /// hierarchy: the sheet's list is a CollectionView, NOT a Table), so
    /// probe the collection view first and keep the table fallback.
    private func scrollToExists(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 2) { return }
        let scroller: XCUIElement
        if app.collectionViews.firstMatch.waitForExistence(timeout: 3) {
            scroller = app.collectionViews.firstMatch
        } else {
            XCTAssertTrue(
                app.tables.firstMatch.waitForExistence(timeout: 3),
                app.debugDescription
            )
            scroller = app.tables.firstMatch
        }
        for _ in 0..<6 {
            scroller.swipeUp()
            if element.exists { return }
        }
        for _ in 0..<8 {
            scroller.swipeDown()
            if element.exists { return }
        }
        XCTAssertTrue(
            element.waitForExistence(timeout: 2),
            "Element never realized after bounded bidirectional scrolling.\n\(app.debugDescription)"
        )
    }
}
