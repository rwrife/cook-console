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
        dismissKeyboard()
        tapWhenHittable(app.buttons["Ingredient unit 1"], scrolling: form)
        tapWhenHittable(app.buttons["cup"])
        enterText("Simmer gently.", in: app.textViews["Step 1"], form: form)
        dismissKeyboard()
        if let secondStep {
            tapWhenHittable(app.buttons["Add Step"], scrolling: form)
            enterText(secondStep, in: app.textViews["Step 2"], form: form)
            dismissKeyboard()
        }
        enterText("quick, dinner", in: app.textFields["Tags"], form: form)
        dismissKeyboard()
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

    private func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        tapWhenHittable(app.buttons["Done Editing"])
        // Hosted simulator AX snapshots can take longer than two seconds even
        // after the keyboard is gone. Use XCTest's disappearance API, not a
        // predicate whose first snapshot can consume its entire timeout.
        let disappeared = keyboard.waitForNonExistence(timeout: 10)
        if !disappeared {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Keyboard dismissal failure UI hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(
            disappeared,
            "Keyboard remained visible after Done Editing.\n\(keyboard.debugDescription)"
        )
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
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return
            }
            container.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }
}
