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

    func testStepTimersStartPauseResumeExtendCancelAndRunConcurrently() {
        createRecipe(
            title: "Timed Soup",
            secondStep: "Rest before serving.",
            timerMinutes: "10",
            secondTimerMinutes: "5"
        )
        app.buttons["Timed Soup"].tap()
        app.buttons["Cook"].tap()
        let cookScrollView = app.scrollViews.firstMatch

        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)
        XCTAssertTrue(app.staticTexts["Timer notification fallback"].exists)
        tapWhenHittable(app.buttons["Pause timer"], scrolling: cookScrollView)
        tapWhenHittable(app.buttons["Resume timer"], scrolling: cookScrollView)
        tapWhenHittable(app.buttons["Extend timer by 2 minutes"], scrolling: cookScrollView)

        app.buttons["Next step"].tap()
        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)
        XCTAssertEqual(app.buttons.matching(identifier: "Pause timer").count, 2)

        app.buttons.matching(identifier: "Cancel timer").firstMatch.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Pause timer").count, 1)
    }

    func testRunningTimerSurvivesProcessRelaunch() {
        createRecipe(title: "Relaunch Rice", timerMinutes: "10")
        app.buttons["Relaunch Rice"].tap()
        app.buttons["Cook"].tap()
        tapWhenHittable(app.buttons["Start step timer"], scrolling: app.scrollViews.firstMatch)
        XCTAssertTrue(app.buttons["Pause timer"].exists)

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["Relaunch Rice"].tap()
        app.buttons["Cook"].tap()

        XCTAssertTrue(app.buttons["Pause timer"].waitForExistence(timeout: 2))
    }

    func testDeniedShortTimerCompletesInCookCoverAndAfterFullRecipeExit() {
        app.terminate()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-short-timer-fixture"]
        app.launch()

        app.buttons["Short Timer Fixture"].tap()
        app.buttons["Cook"].tap()
        let cookScrollView = app.scrollViews.firstMatch
        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)
        XCTAssertTrue(app.staticTexts["Timer notification fallback"].exists)

        let completion = app.alerts["Timer Finished"]
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        XCTAssertTrue(completion.staticTexts["Step 1: Rest briefly. timer finished."].exists)
        acknowledgeCompletion(completion)

        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)
        app.buttons["Full recipe"].tap()
        XCTAssertTrue(app.navigationBars["Short Timer Fixture"].waitForExistence(timeout: 2))
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        XCTAssertTrue(completion.staticTexts["Step 1: Rest briefly. timer finished."].exists)
        acknowledgeCompletion(completion)
    }

    func testConsecutiveQueuedCompletionAlertsPresentInOrder() throws {
        // Staggered fixture (seeded by AppStore): step 1 fires at 20s and
        // step 2 fires 40s after its own start (which itself begins several
        // seconds into the test), so completion order is strict regardless of
        // how long the UI needs to navigate, and step 2's alert can never
        // appear inside the 10s dismissal window asserted after the first OK.
        app.terminate()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-staggered-timer-fixture"]
        app.launch()

        app.buttons["Staggered Timer Fixture"].tap()
        app.buttons["Cook"].tap()
        let cookScrollView = app.scrollViews.firstMatch

        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)
        app.buttons["Next step"].tap()
        tapWhenHittable(app.buttons["Start step timer"], scrolling: cookScrollView)

        let firstCompletion = app.alerts["Timer Finished"]
        XCTAssertTrue(firstCompletion.waitForExistence(timeout: 30))
        XCTAssertTrue(
            firstCompletion.staticTexts["Step 1: Boil first. timer finished."].exists
        )
        acknowledgeCompletion(firstCompletion)
        // Prove the first alert is gone before evaluating the second, so a
        // lingering outgoing alert can never satisfy the next wait.
        XCTAssertTrue(
            firstCompletion.waitForNonExistence(timeout: 10),
            "First completion alert never dismissed.\n\(app.debugDescription)"
        )

        let secondCompletion = app.alerts["Timer Finished"]
        XCTAssertTrue(secondCompletion.waitForExistence(timeout: 35))
        XCTAssertTrue(
            secondCompletion.staticTexts["Step 2: Rest second. timer finished."].exists
        )
        acknowledgeCompletion(secondCompletion)
    }

    private func createRecipe(
        title: String,
        secondStep: String? = nil,
        timerMinutes: String? = nil,
        secondTimerMinutes: String? = nil
    ) {
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
        if let timerMinutes {
            enterText(timerMinutes, in: app.textFields["Step timer 1"], form: form)
            dismissKeyboard()
        }
        if let secondStep {
            tapWhenHittable(app.buttons["Add Step"], scrolling: form)
            enterText(secondStep, in: app.textViews["Step 2"], form: form)
            dismissKeyboard()
            if let secondTimerMinutes {
                enterText(secondTimerMinutes, in: app.textFields["Step timer 2"], form: form)
                dismissKeyboard()
            }
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

    /// Taps the completion alert's OK button and proves the alert actually
    /// disappears, retrying the tap while the (still-presented) alert remains
    /// up. The app's acknowledgment is guarded and idempotent
    /// (`presentedCompletionID` is consumed on first ack), so repeat taps
    /// cannot acknowledge a second queue entry; the retry only compensates
    /// for synthesized touches the simulator drops mid alert animation
    /// (observed in run 35379410135: OK tapped at t=61s but the alert was
    /// still presenting for the full 10s window).
    private func acknowledgeCompletion(_ alert: XCUIElement) {
        let ok = alert.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        ok.tap()
        var disappeared = alert.waitForNonExistence(timeout: 10)
        var attempts = 1
        while !disappeared && attempts < 4 {
            attempts += 1
            if ok.waitForExistence(timeout: 2) {
                ok.tap()
                disappeared = alert.waitForNonExistence(timeout: 10)
            } else {
                break
            }
        }
        XCTAssertTrue(
            disappeared,
            "Completion alert never dismissed after \(attempts) OK taps.\n\(app.debugDescription)"
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
            // A closed SwiftUI menu Picker still exposes its option buttons in
            // the hierarchy with zero-size frames. Existence alone therefore
            // does not prove the menu finished presenting, and acting
            // immediately can see `{{inf, inf}, {0, 0}}` activation points.
            // Poll for hittability within a bounded window while keeping the
            // strict hittability gate before any tap. The runner process is
            // separate from the app, so this never blocks the app's main
            // actor.
            let deadline = Date().addingTimeInterval(5)
            var hittable = element.isHittable
            while !hittable && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                hittable = element.isHittable
            }
            XCTAssertTrue(
                hittable,
                "Element never became hittable within 5s.\n\(element.debugDescription)"
            )
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
