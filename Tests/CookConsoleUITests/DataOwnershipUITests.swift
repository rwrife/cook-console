import XCTest

/// Backup/recovery UI, using deterministic local fixtures for preview/apply.
/// System Files save/cancel is verified manually; the real domain service
/// tests prove that preparing JSON or exporting CSV never confirms a backup.
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

        // File generation is never a confirmation; system Files UI is covered manually.
        scrollUntilVisible(app.staticTexts["Last confirmed backup"])
        XCTAssertTrue(app.staticTexts["Last confirmed backup"].label.contains("No confirmed"))
        scrollToExists(app.staticTexts["Backup contents"])
        XCTAssertTrue(app.staticTexts["Backup contents"].label.contains("Excludes pantry"))
        XCTAssertTrue(app.staticTexts["Backup contents"].label.contains("starter cookbook"))

        // CSV history export the same way (same hittable-scroll discipline).
        scrollUntilVisible(app.buttons["Export CSV history"])
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

    func testPreviewCancelApplyAndArchiveRestoreJourney() {
        app.terminate()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-recovery-fixture"]
        app.launch()
        app.buttons["Your data"].tap()
        scrollUntilVisible(app.buttons["Preview recovery fixture"])
        app.buttons["Preview recovery fixture"].tap()
        XCTAssertTrue(app.staticTexts["Import preview summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Import preview summary"].label.contains("1 recipes replaced"))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Import summary"].exists)
        scrollUntilVisible(app.buttons["Preview recovery fixture"])
        app.buttons["Preview recovery fixture"].tap()
        XCTAssertTrue(app.buttons["Apply JSON import"].waitForExistence(timeout: 5))
        app.buttons["Apply JSON import"].tap()
        scrollToExists(app.staticTexts["Import summary"])
        XCTAssertTrue(app.staticTexts["Import summary"].label.contains("1 recipes replaced"))
        // Dismiss the data sheet using its existing Done button.
        app.buttons["Done"].tap()
        let recipe = app.descendants(matching: .any).matching(identifier: "Recipe row Recovered Fixture").firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 5), app.debugDescription)
        recipe.tap()
        scrollUntilVisible(app.buttons["Delete recipe"])
        app.buttons["Delete recipe"].tap()
        let confirmation = app.sheets.buttons["Delete recipe"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        confirmation.tap()
        app.buttons["Your data"].tap()
        scrollUntilVisible(app.buttons["Restore recipe Recovered Fixture"])
        app.buttons["Restore recipe Recovered Fixture"].tap()
        scrollToExists(app.staticTexts["Archive retention"])
        XCTAssertFalse(app.buttons["Restore recipe Recovered Fixture"].exists)
    }

    /// Scroll the sheet's list until the element's AX frame sits fully
    /// BELOW the sheet's navigation bar. Two weaker gates failed on the
    /// hosted runner:
    /// - existence (run 35619636791): after the privacy sweeps the export
    ///   cell stays mounted in the CollectionView AX tree with its frame
    ///   clipped above the scroll top, the tap synthesizes onto the nav
    ///   bar / status-bar strip over it, and 'Export ready' never presents.
    /// - isHittable (run 35754199760): XCTest reported the RAW AX frame
    ///   ({{16.0, 31.3} …} under a CollectionView starting at y=62, behind
    ///   a sheet nav bar spanning y=78…132) as hittable; the gate never
    ///   saw the clip and the tap again landed on dead space.
    /// Frame-vs-navbar geometry is the only gate that sees the clip: a
    /// center tap below the nav bar's bottom edge always lands on the row.
    /// Direction: swipeDown — the export buttons live ABOVE the privacy
    /// section the earlier sweeps parked at. iOS 26 List bridges to
    /// UICollectionView: probe collectionViews first, table fallback.
    private func scrollUntilVisible(_ element: XCUIElement) {
        scrollToExists(element)
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
        // The presented sheet's nav bar is an opaque touch-capturing strip:
        // tapping a row whose center is under it is a dead tap.
        var safeTop = scroller.frame.minY
        let sheetBar = app.navigationBars["Your Data"].exists ? app.navigationBars["Your Data"] : app.navigationBars.firstMatch
        if sheetBar.exists {
            safeTop = max(safeTop, sheetBar.frame.maxY)
        }
        for _ in 0..<12 {
            if element.exists, element.frame.minY >= safeTop, element.frame.maxY <= scroller.frame.maxY { return }
            if element.exists, element.frame.maxY > scroller.frame.maxY { scroller.swipeUp() }
            else { scroller.swipeDown() }
        }
        XCTAssertTrue(
            element.exists && element.frame.minY >= safeTop && element.frame.maxY <= scroller.frame.maxY,
            "Element center never moved below the sheet nav bar (safeTop=\(safeTop)).\n\n\(app.debugDescription)"
        )
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
