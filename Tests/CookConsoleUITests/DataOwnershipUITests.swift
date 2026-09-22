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
        // Hittable scroll, not just existence: after the privacy-statement
        // sweeps the sheet sits at the bottom and the export cell stays
        // mounted in the CollectionView AX tree with a frame clipped under
        // the navigation bar (run 35619636791: button frame y=31.3 under a
        // nav bar starting at y=78 — the tap synthesized onto dead space
        // and the "Export ready" alert never presented).
        scrollUntilVisible(app.buttons["Export JSON backup"])
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
        XCTAssertTrue(
            element.waitForExistence(timeout: 5),
            app.debugDescription
        )
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
        let sheetBar = app.navigationBars["Your Data"]
        if sheetBar.exists {
            safeTop = max(safeTop, sheetBar.frame.maxY)
        }
        for _ in 0..<12 {
            if element.exists, element.frame.midY >= safeTop { return }
            scroller.swipeDown()
        }
        XCTAssertTrue(
            element.exists && element.frame.midY >= safeTop,
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
