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
        XCTAssertTrue(app.staticTexts["2 1/2 cup Stock"].waitForExistence(timeout: 1))
        app.buttons["Reset servings"].tap()
        XCTAssertTrue(app.staticTexts["2 cup Stock"].waitForExistence(timeout: 1))
    }

    func testPracticalScalingDisclosesRoundingEggsPanAndTimeGuidance() {
        app.terminate()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-scaling-fixture"]
        app.launch()

        XCTAssertTrue(app.buttons["Scaling Cake"].waitForExistence(timeout: 3))
        app.buttons["Scaling Cake"].tap()
        app.buttons["Increase servings by half"].tap()

        let detail = app.collectionViews.firstMatch
        XCTAssertTrue(app.staticTexts["1 1/2 cup Flour"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["Rounding disclosure Flour"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Ingredient guidance Eggs"].exists
        )
        let panGuidance = app.descendants(matching: .any)["Pan size guidance"]
        scrollToExists(panGuidance, in: detail)
        XCTAssertTrue(panGuidance.label.contains("Use two prepared 8-inch pans."))
        let timeGuidance = app.descendants(matching: .any)["Cooking time guidance"]
        // Sibling rows below the pan guidance are lazily mounted by the iOS 26
        // CollectionView bridge: "exists" was true for pan guidance but false
        // for the row beneath it in run 36549317916 (:58) because scrolling
        // stopped at the first already-mounted row. Scroll for each row
        // individually before asserting on it.
        scrollToExists(timeGuidance, in: detail)
        XCTAssertTrue(timeGuidance.label.contains("Keep the original bake time and test both pans."))
        XCTAssertTrue(app.descendants(matching: .any)["Scaling rounding disclosure"].exists)

        scrollToExists(app.buttons["Reset servings"], in: detail)
        app.buttons["Reset servings"].tap()
        let resetFlour = app.staticTexts["1 1/8 cup Flour"]
        // Reset removes the scaling-guidance rows above the ingredient list.
        // On iOS 26's lazy CollectionView bridge the resulting layout change
        // can leave the restored ingredient outside the mounted AX window even
        // though reset succeeded. Scroll back to the ingredient before proving
        // the original display amount was restored.
        scrollToExists(resetFlour, in: detail)
        XCTAssertTrue(resetFlour.exists)
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

    func testWhatCanIMakeSuggestsRecipesFromPantryAndShowsMissingIngredients() {
        app.terminate()
        app.launchArguments = ["-ui-testing-reset", "-ui-testing-pantry-fixture"]
        app.launch()

        XCTAssertTrue(app.buttons["Simple Omelet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["What Can I Make?"].waitForExistence(timeout: 2))
        app.buttons["What Can I Make?"].tap()

        XCTAssertTrue(app.staticTexts["Pantry quantity disclaimer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Assumed Pantry Staples"].exists)

        // Add "eggs" into ingredients on hand
        let addField = app.textFields["Add pantry ingredient field"]
        XCTAssertTrue(addField.waitForExistence(timeout: 2))
        addField.tap()
        addField.typeText("Eggs")
        app.buttons["Add pantry ingredient button"].tap()

        // "Simple Omelet" requires Eggs + Salt. Salt is a default staple, so Simple Omelet is Ready!
        XCTAssertTrue(app.descendants(matching: .any)["Ready badge Simple Omelet"].waitForExistence(timeout: 3))

        // "Bean Salad" requires Chickpeas and Fresh basil -> neither in pantry yet -> 2 missing
        XCTAssertTrue(app.descendants(matching: .any)["Missing badge Bean Salad"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Missing list Bean Salad"].label.contains("Chickpeas"))

        // Add conservative alias: "garbanzo beans" should match "Chickpeas"
        addField.tap()
        addField.typeText("garbanzo beans")
        app.buttons["Add pantry ingredient button"].tap()

        // Bean Salad now only has 1 missing (Fresh basil)
        XCTAssertTrue(app.descendants(matching: .any)["Missing list Bean Salad"].label.contains("Fresh basil"))
        XCTAssertFalse(app.descendants(matching: .any)["Missing list Bean Salad"].label.contains("Chickpeas"))

        // Tap on Simple Omelet from suggestions to open recipe detail
        app.buttons["Pantry suggestion Simple Omelet"].tap()
        XCTAssertTrue(app.navigationBars["Simple Omelet"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["Open Notification Settings"].exists)
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
        // Staggered fixture (seeded by AppStore): step 1 expires 20s after
        // its start and step 2 expires 120s after its own start. Run
        // 35619636791 proved the old 40s step was not enough: the hosted
        // runner needed ~31s to discover step 1's alert and its OK-tap/retry
        // path can consume ~45s more, so step 2 (fired at t=61s) landed
        // INSIDE step 1's dismissal windows and re-satisfied the shared
        // "Timer Finished" identifier. 120s separates them beyond any
        // realistic acknowledgment path; per-step message text remains the
        // assertion discriminator.
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
        // Prove the FIRST completion's message left the UI before evaluating
        // the second. Alert-level non-existence is the wrong proof: the
        // identifier "Timer Finished" is shared, so when step 2 completes
        // inside the check window its alert re-satisfies existence and the
        // old assertion failed despite a perfect queue (run 35619636791
        // :161 — failure hierarchy showed the alert up with step 2's
        // message). The message-scoped query is the durable discriminator.
        XCTAssertFalse(
            app.staticTexts["Step 1: Boil first. timer finished."].exists,
            "Step 1's completion message was still on screen after acknowledgment.\n\n\(app.debugDescription)"
        )

        let secondCompletion = app.alerts["Timer Finished"]
        // Step 2 expires ~120s after its start; acknowledgment of step 1 can
        // consume up to ~75s on a slow hosted runner, so wait generously.
        XCTAssertTrue(secondCompletion.waitForExistence(timeout: 150))
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

    private func scrollToExists(_ element: XCUIElement, in container: XCUIElement) {
        for _ in 0..<10 {
            if element.exists {
                return
            }
            container.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
    }
}
