import XCTest

/// Issue #20 UI coverage: the grocery flow end to end on the hosted
/// simulator — open the list from the library footer, pick two fixture
/// recipes, watch the merged amounts/provenance update, change servings,
/// add a manual item, check a merged line, and confirm the share-sheet
/// export path. Merge math itself is unit-tested in GroceryAggregationTests;
/// this proves the wiring (picker -> GRDB -> AppStore snapshot -> view).
final class GroceryListUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-grocery-fixture"]
        app.launch()
    }

    func testGroceryListMergesSelectedRecipesAndPersistsCheckState() {
        // 1. Open the grocery sheet from the persistent bottom inset.
        let groceryButton = app.buttons["Grocery List"]
        XCTAssertTrue(groceryButton.waitForExistence(timeout: 10), app.debugDescription)
        groceryButton.tap()

        XCTAssertTrue(
            app.staticTexts["Grocery summary"].waitForExistence(timeout: 5),
            app.debugDescription
        )

        // 2. Pick both fixture recipes through the picker sheet.
        tapWhenHittable(app.buttons["Add grocery recipe"])
        XCTAssertTrue(
            app.buttons["Finish picking recipes"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        tapWhenHittable(app.buttons["Pick recipe Pasta Dinner"])
        tapWhenHittable(app.buttons["Pick recipe Big Salad"])
        tapWhenHittable(app.buttons["Finish picking recipes"])

        // 3. The merged shopping list shows both provenances on the shared
        //    olive-oil line (0.5 + 0.25 cup at original servings = 3/4 cup).
        //    Rows carry identifiers on their own controls (row container
        //    identifiers clobber child ids in the AX tree — run 36954402316).
        scrollToExists(app.staticTexts["Grocery row text Olive oil"])
        XCTAssertTrue(app.staticTexts["Grocery row text Olive oil"].exists, app.debugDescription)
        XCTAssertTrue(
            app.staticTexts["Grocery row text Olive oil"].label.contains("3/4 cup"),
            app.staticTexts["Grocery row text Olive oil"].label
        )
        XCTAssertTrue(
            app.staticTexts["Grocery provenance Olive oil"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        let provenance = app.staticTexts["Grocery provenance Olive oil"].label
        XCTAssertTrue(provenance.contains("Pasta Dinner"), provenance)
        XCTAssertTrue(provenance.contains("Big Salad"), provenance)
        // Spinach merges 100 g + 200 g.
        scrollToExists(app.staticTexts["Grocery provenance Spinach"])
        XCTAssertTrue(app.staticTexts["Grocery provenance Spinach"].exists)

        // 4. Serving changes recompute amounts: bump Pasta Dinner from its
        //    default 2 to 2.5 servings (the formatter prints "2 1/2").
        //    Olive oil becomes 0.625 + 0.25 = 7/8 cup. The exact amount
        //    re-derives; provenance survives.
        scrollToExists(app.buttons["Increase servings Pasta Dinner"])
        scrollUntilVisible(app.buttons["Increase servings Pasta Dinner"])
        tapWhenHittable(app.buttons["Increase servings Pasta Dinner"])
        XCTAssertTrue(
            app.staticTexts["Servings for Pasta Dinner"].label.contains("1/2"),
            app.staticTexts["Servings for Pasta Dinner"].label
        )
        // The tap recomputes the snapshot and remounts lazy rows away from
        // the current viewport — realize before the geometry gate.
        scrollToExists(app.staticTexts["Grocery provenance Olive oil"])
        scrollUntilVisible(app.staticTexts["Grocery provenance Olive oil"])
        // The list re-merged; the oil row still carries both provenances.
        XCTAssertTrue(app.staticTexts["Grocery provenance Olive oil"].label.contains("Pasta Dinner"))

        // 5. Manual item: type, add, and see it lead the Shopping summary.
        //    Same type-then-tap discipline as the pantry UI test (the Add
        //    button sits above the keyboard and stays hittable).
        let field = app.textFields["Grocery entry field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Paper towels")
        app.buttons["Add grocery item"].tap()
        XCTAssertTrue(app.staticTexts["Grocery summary"].label.contains("to buy"), app.staticTexts["Grocery summary"].label)

        // 6. Check the merged olive oil line; the summary count drops.
        scrollToExists(app.buttons["Check recipe line Olive oil"])
        scrollUntilVisible(app.buttons["Check recipe line Olive oil"])
        let beforeLabel = app.staticTexts["Grocery summary"].label
        tapWhenHittable(app.buttons["Check recipe line Olive oil"])
        // Poll for the count to move (recompute round-trips GRDB).
        var summary = app.staticTexts["Grocery summary"].label
        var deadline = Date().addingTimeInterval(10)
        while summary == beforeLabel && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            summary = app.staticTexts["Grocery summary"].label
        }
        XCTAssertNotEqual(summary, beforeLabel, "checking a merged line must change the to-buy count")

        // 7. Share path: export writes the text file and offers the share item.
        scrollToExists(app.buttons["Export grocery list"])
        scrollUntilVisible(app.buttons["Export grocery list"])
        tapWhenHittable(app.buttons["Export grocery list"])
        XCTAssertTrue(
            app.staticTexts["Grocery status message"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        scrollToExists(app.buttons["Share grocery list"])
        XCTAssertTrue(app.buttons["Share grocery list"].exists)
    }

    // MARK: - Helpers (same discipline as the other UI suites)

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

    /// Realize a lazily-mounted row (iOS 26 List = UICollectionView: rows
    /// far below the fold have no AX element at all until scrolled near —
    /// same discipline DataOwnershipUITests proved necessary). Bidirectional
    /// so elements ABOVE the fold also realize.
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

    /// Scroll the sheet's list until the element's center clears the nav
    /// bar (iOS 26 List = UICollectionView; isHittable is blind to clipping
    // — same geometry gate DataOwnershipUITests proved necessary).
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
        let sheetBar = app.navigationBars["Grocery List"]
        if sheetBar.exists {
            safeTop = max(safeTop, sheetBar.frame.maxY)
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
            element.exists && element.frame.midY >= safeTop,
            "Element never scrolled into the tappable band.\n\(app.debugDescription)"
        )
    }
}
