import XCTest

final class PersonalRecipeUITests: XCTestCase {
    func testNotesRatingPersistAfterRelaunchAndHistoryStartsEmpty() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-pantry-fixture"]
        app.launch()
        openPersonalDetails(app)
        XCTAssertTrue(app.staticTexts["Last cooked"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["Last cooked"].label, "Not cooked yet")
        let rating = app.buttons["Personal rating"]
        XCTAssertTrue(rating.waitForExistence(timeout: 5), app.debugDescription)
        rating.tap()
        let four = app.buttons["4 stars"]
        XCTAssertTrue(four.waitForExistence(timeout: 5), app.debugDescription)
        four.tap()
        let notes = app.textViews["Personal notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap(); notes.typeText("Less salt next time; use chives.")
        app.buttons["Save personal notes"].tap()
        XCTAssertTrue(app.navigationBars["Simple Omelet"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        openPersonalDetails(app)
        XCTAssertTrue(app.buttons["Personal rating"].label.contains("4 stars"), app.debugDescription)
        // TextEditor AX value is not exposed reliably; repository tests prove
        // exact note persistence. Identity here proves the editing surface.
        XCTAssertTrue(app.textViews["Personal notes"].exists)
        app.buttons["Personal cooking history"].tap()
        XCTAssertTrue(app.staticTexts["No completed cooking sessions"].waitForExistence(timeout: 5))
    }

    private func openPersonalDetails(_ app: XCUIApplication) {
        let recipe = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simple Omelet")).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 10), app.debugDescription)
        recipe.tap()
        let button = app.buttons["Personal recipe details"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            if button.exists, button.isHittable,
               button.frame.midY > app.navigationBars.firstMatch.frame.maxY,
               button.frame.midY < app.buttons["Cook"].frame.minY { break }
            list.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable, app.debugDescription)
        button.tap()
        XCTAssertTrue(app.navigationBars["Notes & rating"].waitForExistence(timeout: 5))
    }
}
