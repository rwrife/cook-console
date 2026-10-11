import XCTest

final class CookPrepUITests: XCTestCase {
    func testPrepKeepsSessionPositionAndServingsAcrossReentry() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-a11y-recipe-fixture"]
        app.launch()
        app.buttons["A11y Soup"].tap()
        app.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Next step preview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["Next step preview"].label.contains("crusty bread"))
        let ingredients = app.buttons["Ingredients"]
        for _ in 0..<6 where !ingredients.isHittable { app.scrollViews.firstMatch.swipeUp() }
        ingredients.tap()
        XCTAssertTrue(app.staticTexts["Prep servings"].waitForExistence(timeout: 5))
        app.buttons["More servings"].tap()
        XCTAssertTrue(app.staticTexts["Servings: 4.5"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Next step"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].waitForExistence(timeout: 5))
        app.buttons["Full recipe"].tap()
        app.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].waitForExistence(timeout: 5))
        let reopen = app.buttons["Ingredients"]
        for _ in 0..<6 where !reopen.isHittable { app.scrollViews.firstMatch.swipeUp() }
        reopen.tap()
        XCTAssertTrue(app.staticTexts["Servings: 4.5"].waitForExistence(timeout: 5))
    }
}
