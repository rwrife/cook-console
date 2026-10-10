import XCTest

final class StarterCookbookUITests: XCTestCase {
    func testReviewAcceptAndRelaunchDoesNotDuplicateRecipes() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
        app.buttons["Starter Cookbook"].tap()
        XCTAssertTrue(app.staticTexts["Starter update introduction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Starter update introduction"].label.contains("2 recipes"))
        let recipeLink = app.buttons["Review starter Simple Stovetop Oats"]
        reveal(recipeLink, in: app)
        recipeLink.tap()
        XCTAssertTrue(app.staticTexts["Starter bundled title"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let accept = app.buttons["Accept Starter Update"]
        reveal(accept, in: app)
        accept.tap()
        XCTAssertTrue(app.staticTexts["No pending starter update"].waitForExistence(timeout: 5))
        app.buttons["Close Starter Cookbook"].tap()
        XCTAssertTrue(app.buttons["Recipe row Simple Stovetop Oats"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["Starter Cookbook"].tap()
        XCTAssertTrue(app.staticTexts["No pending starter update"].waitForExistence(timeout: 5))
    }

    func testSkipSurvivesRelaunchAndLeavesLibraryEmpty() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
        app.buttons["Starter Cookbook"].tap()
        let skip = app.buttons["Skip Starter Version"]
        reveal(skip, in: app)
        skip.tap()
        app.buttons["Close Starter Cookbook"].tap()
        XCTAssertTrue(app.staticTexts["No Recipes"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["Starter Cookbook"].tap()
        XCTAssertTrue(app.staticTexts["No pending starter update"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            let top = max(list.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            if element.exists, element.isHittable, element.frame.minY >= top,
               element.frame.maxY <= list.frame.maxY { return }
            if element.exists && element.frame.minY < top { list.swipeDown() }
            else { list.swipeUp() }
        }
        XCTFail("Starter action is not visible: " + element.description)
    }
}
