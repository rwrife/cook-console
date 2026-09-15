import XCTest

final class RecipeWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
    }

    func testCreateRecipeReturnsToLibraryWithCompleteRecipe() {
        createRecipe(title: "Weeknight Soup")

        XCTAssertTrue(app.navigationBars["Recipes"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Weeknight Soup"].exists)

        app.buttons["Weeknight Soup"].tap()
        XCTAssertTrue(app.staticTexts["2 cup Stock"].exists)
        XCTAssertTrue(app.staticTexts["Simmer gently."].exists)
        XCTAssertTrue(app.staticTexts["quick"].exists)
    }

    func testScalingUpdatesAmountsImmediatelyAndResetRestoresBaseServings() {
        createRecipe(title: "Scaled Soup")
        app.buttons["Scaled Soup"].tap()

        XCTAssertTrue(app.staticTexts["2 cup Stock"].exists)
        app.buttons["Increase servings by half"].tap()
        XCTAssertTrue(app.staticTexts["2.5 cup Stock"].waitForExistence(timeout: 1))
        app.buttons["Reset servings"].tap()
        XCTAssertTrue(app.staticTexts["2 cup Stock"].waitForExistence(timeout: 1))
    }

    func testCookNavigationAndFullRecipeEscapePreservePosition() {
        createRecipe(title: "Cook Soup", secondStep: "Serve warm.")
        app.buttons["Cook Soup"].tap()
        app.buttons["Cook"].tap()

        XCTAssertTrue(app.staticTexts["Step 1 of 2"].exists)
        XCTAssertTrue(app.staticTexts["Simmer gently."].exists)
        app.buttons["Next step"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].exists)
        XCTAssertTrue(app.staticTexts["Serve warm."].exists)
        app.buttons["Previous step"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].exists)
        app.buttons["Next step"].tap()

        app.buttons["Full recipe"].tap()
        XCTAssertTrue(app.navigationBars["Cook Soup"].exists)
        app.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].exists)
    }

    func testActiveSearchRemainsAppliedAfterSave() {
        let searchField = app.searchFields["Search titles"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        searchField.typeText("Matching")

        createRecipe(title: "Different Recipe")

        XCTAssertEqual(searchField.value as? String, "Matching")
        XCTAssertFalse(app.buttons["Different Recipe"].exists)
        XCTAssertTrue(app.staticTexts["No Recipes"].waitForExistence(timeout: 2))
    }

    private func createRecipe(title: String, secondStep: String? = nil) {
        tapWhenHittable(app.buttons["Add Recipe"])
        let form = app.descendants(matching: .any)["Recipe editor form"]
        XCTAssertTrue(form.waitForExistence(timeout: 2))
        enterText(title, in: app.textFields["Recipe title"], form: form)
        replaceText(in: app.textFields["Servings"], with: "2")
        enterText("Stock", in: app.textFields["Ingredient name 1"], form: form)
        replaceText(in: app.textFields["Ingredient amount 1"], with: "2")
        dismissKeyboard(in: form)
        tapWhenHittable(app.buttons["Ingredient unit 1"], scrolling: form)
        tapWhenHittable(app.buttons["cup"])
        enterText("Simmer gently.", in: app.textViews["Step 1"], form: form)
        if let secondStep {
            dismissKeyboard(in: form)
            tapWhenHittable(app.buttons["Add Step"], scrolling: form)
            enterText(secondStep, in: app.textViews["Step 2"], form: form)
        }
        enterText("quick, dinner", in: app.textFields["Tags"], form: form)
        dismissKeyboard(in: form)
        tapWhenHittable(app.buttons["Save Recipe"], scrolling: form)
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        let form = app.descendants(matching: .any)["Recipe editor form"]
        scrollToHittable(element, in: form)
        element.tap()
        if let currentValue = element.value as? String {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            )
        }
        element.typeText(value)
    }

    private func enterText(_ text: String, in element: XCUIElement, form: XCUIElement) {
        scrollToHittable(element, in: form)
        element.tap()
        element.typeText(text)
    }

    private func dismissKeyboard(in form: XCUIElement) {
        guard app.keyboards.firstMatch.exists else { return }
        form.swipeUp()
        let hidden = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(
            predicate: hidden,
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed)
    }

    private func tapWhenHittable(
        _ element: XCUIElement,
        scrolling container: XCUIElement? = nil
    ) {
        if let container {
            scrollToHittable(element, in: container)
        } else {
            XCTAssertTrue(element.waitForExistence(timeout: 2))
            XCTAssertTrue(element.isHittable)
        }
        element.tap()
    }

    private func scrollToHittable(_ element: XCUIElement, in container: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        for _ in 0..<8 where !element.isHittable {
            container.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
