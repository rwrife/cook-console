import XCTest

/// Issue #21: review board journey — pack desk truth is visible even for
/// recipes not installed on the device, the local recipe outside the pack
/// is surfaced as notInReviewPack, and recording a kitchen test (notes
/// mandatory) flips its state badge and the coverage counters.
final class RecipeReviewBoardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-review-fixture"]
        app.launch()
    }

    func testReviewBoardShowsDeskStatusAndRecordsKitchenTest() {
        openReviewBoard()

        // Desk truth from the bundled pack is visible with no pack
        // recipes installed — coverage must never look "complete".
        let gapCounts = app.staticTexts["Review gap counts"]
        XCTAssertTrue(gapCounts.waitForExistence(timeout: 5))
        XCTAssertTrue(gapCounts.label.contains("Desk review passed: 5"), gapCounts.label)
        XCTAssertTrue(gapCounts.label.contains("defects open: 1"), gapCounts.label)
        XCTAssertTrue(gapCounts.label.contains("kitchen-tested: 0"), gapCounts.label)

        XCTAssertTrue(app.staticTexts["Desk state Chickpea Salad"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Desk state Chickpea Salad"].label.contains("Desk defect open"))
        XCTAssertTrue(app.staticTexts["Queue priority Chickpea Salad"].label.contains("#1"))
        XCTAssertTrue(app.staticTexts["Kitchen state Sunday Pancakes"].label.contains("not tested"))

        // The local fixture recipe is outside the pack and shows as such.
        let roastDesk = app.staticTexts["Desk state Review Board Roast"]
        scrollUntilVisible(roastDesk)
        XCTAssertTrue(roastDesk.label.contains("Not in review pack"))

        // Record a physical kitchen test against the local recipe.
        let record = app.buttons["Record Kitchen Test"]
        scrollUntilVisible(record)
        tapWhenHittable(record)
        XCTAssertTrue(app.navigationBars["Kitchen Test"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Review Board Roast"].waitForExistence(timeout: 2))

        // Save is disabled until the mandatory notes field has content.
        let saveButton = app.buttons["Save Kitchen Test"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), app.debugDescription)
        scrollUntilVisible(saveButton)
        XCTAssertFalse(saveButton.isEnabled)
        let notesField = app.textViews["Test notes field"].exists
            ? app.textViews["Test notes field"]
            : app.textFields["Test notes field"]
        XCTAssertTrue(notesField.waitForExistence(timeout: 3), app.debugDescription)
        notesField.tap()
        XCTAssertTrue(notesField.waitForExistence(timeout: 2))
        notesField.typeText("Roasted at 200C for 25 min; edges golden, centers tender.")
        dismissKeyboardIfNeeded()

        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        // Board reflects the durable observation.
        XCTAssertTrue(gapCounts.waitForExistence(timeout: 3))
        XCTAssertTrue(gapCounts.label.contains("kitchen-tested: 1"), gapCounts.label)
        let roastKitchen = app.staticTexts["Kitchen state Review Board Roast"]
        scrollUntilVisible(roastKitchen)
        XCTAssertTrue(roastKitchen.label.contains("passed"), roastKitchen.label)
    }

    // MARK: - Helpers (proven patterns from #20)

    private func openReviewBoard() {
        let review = app.buttons["Recipe Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        scrollUntilVisible(review)
        tapWhenHittable(review)
        XCTAssertTrue(app.navigationBars["Recipe Review"].waitForExistence(timeout: 5))
    }

    private func tapWhenHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), element.debugDescription)
        let deadline = Date().addingTimeInterval(5)
        var hittable = element.isHittable
        while !hittable && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            hittable = element.isHittable
        }
        XCTAssertTrue(hittable, "Element never became hittable within 5s.\n\(element.debugDescription)")
        element.tap()
    }

    private func dismissKeyboardIfNeeded() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 2) else { return }
        let done = app.buttons["Done Editing"]
        if done.waitForExistence(timeout: 3), done.isHittable {
            done.tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 10),
            "Keyboard remained visible after dismissal attempt.\n\(keyboard.debugDescription)"
        )
    }

    /// Realize a lazily-mounted element (iOS 26 List = UICollectionView).
    /// Bidirectional so elements ABOVE the fold also realize (#20).
    private func scrollToExists(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 2) { return }
        let scroller: XCUIElement
        if app.collectionViews.firstMatch.waitForExistence(timeout: 3) {
            scroller = app.collectionViews.firstMatch
        } else {
            XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
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
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Element never realized.\n\(app.debugDescription)")
    }

    /// Geometry gate (isHittable is BLIND to CollectionView clipping —
    /// #20 finding): keep scrolling until the element's midY clears the
    /// nav bar and sits inside the scroller, where a center tap lands.
    private func scrollUntilVisible(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let scroller: XCUIElement
        if app.collectionViews.firstMatch.waitForExistence(timeout: 3) {
            scroller = app.collectionViews.firstMatch
        } else {
            XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
            scroller = app.tables.firstMatch
        }
        var safeTop = scroller.frame.minY
        let bar = app.navigationBars.firstMatch
        if bar.exists {
            safeTop = max(safeTop, bar.frame.maxY)
        }
        for _ in 0..<14 {
            if element.exists, element.frame.midY >= safeTop, element.frame.midY <= scroller.frame.maxY {
                return
            }
            if element.frame.midY > scroller.frame.maxY {
                scroller.swipeUp()
            } else {
                scroller.swipeDown()
            }
        }
        XCTAssertTrue(
            element.exists && element.frame.midY >= safeTop && element.frame.midY <= scroller.frame.maxY,
            "Element never scrolled into the tappable band.\n\(element.debugDescription)"
        )
    }
}
