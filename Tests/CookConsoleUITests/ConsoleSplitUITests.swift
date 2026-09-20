import XCTest

/// Issue #5 layout-seam UI coverage. These tests are destination-scoped and
/// the CI workflow runs them with -only-testing on exactly the simulators
/// that can produce the required size class:
///   - `testConsoleSplitViewHostsWorkspaceAtRegularWidth` -> iPad (A16)
///   - `testCookSessionSurvivesRotationAcrossSizeClasses` -> iPhone 17 Pro Max
///     (the only lineup device whose portrait->landscape rotation flips the
///     horizontal size class: compact -> regular, the fold/unfold rehearsal)
/// The main iPhone 17 run skips this class with -skip-testing because
/// neither test can observe a size-class transition there.
final class ConsoleSplitUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Regular-width acceptance: the workspace is a split — console pane
    /// leading, browser/detail trailing — and the console mirrors the
    /// active cook session (now/next) while the detail journey works beside
    /// it. Runs at iPad portrait (regular width).
    func testConsoleSplitViewHostsWorkspaceAtRegularWidth() {
        XCTAssertTrue(
            app.descendants(matching: .any)["Console split pane"].waitForExistence(timeout: 5),
            "Regular width must select the split layout.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["Console workspace"].exists)
        // Fresh launch = empty library; the detail column shows its empty
        // state (the List with the "Recipe browser" id mounts once recipes
        // exist, asserted after creation below).
        XCTAssertTrue(app.staticTexts["No Recipes"].waitForExistence(timeout: 5))
        // Idle pane: mounted split pane with no wall (identifiers attached
        // to ContentUnavailableView do not resolve in AX — see run 5).
        XCTAssertFalse(app.descendants(matching: .any)["Console wall"].exists)

        createTwoStepRecipe(title: "Split Soup")
        XCTAssertTrue(app.buttons["Split Soup"].waitForExistence(timeout: 3))
        app.buttons["Split Soup"].tap()
        XCTAssertTrue(app.buttons["Cook"].waitForExistence(timeout: 2))
        app.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 5))
        app.buttons["Full recipe"].tap()
        XCTAssertTrue(app.navigationBars["Split Soup"].waitForExistence(timeout: 2))

        XCTAssertTrue(
            app.descendants(matching: .any)["Console current step"].waitForExistence(timeout: 5),
            "The console pane must mirror the active cook session.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.navigationBars["Split Soup"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["Console current step"].label.contains("Simmer gently."),
            "Console pane lost the current step position.\n\(app.debugDescription)"
        )
        // The detail column still transports (Cook button present), and the
        // split pane stayed mounted next to it.
        XCTAssertTrue(app.buttons["Cook"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Console split pane"].exists)
    }

    /// Fold/unfold rehearsal: rotate from compact portrait to regular
    /// landscape. The seam must switch strip -> split, keep the browser
    /// navigation (detail showing), and preserve the cook session position
    /// and live timer across the transition. Runs on iPhone 17 Pro Max,
    /// whose rotation flips the horizontal size class.
    func testCookSessionSurvivesRotationAcrossSizeClasses() {
        createTwoStepRecipe(
            title: "Fold Rice",
            secondStep: "Fluff and rest.",
            timerMinutes: "30"
        )
        app.buttons["Fold Rice"].tap()
        app.buttons["Cook"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 5))
        app.buttons["Next step"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].exists)
        tapWhenHittable(
            app.buttons["Start step timer"],
            scrolling: app.scrollViews.firstMatch
        )
        XCTAssertTrue(app.buttons["Pause timer"].waitForExistence(timeout: 2))
        app.buttons["Full recipe"].tap()
        XCTAssertTrue(app.navigationBars["Fold Rice"].waitForExistence(timeout: 2))

        // Portrait, compact: the strip mirrors the session beside the
        // detail, and the split workspace is NOT mounted. ("Console wall"
        // is the wall's guaranteed AX element; layout discrimination is the
        // split pane's presence, which resolves as proven by the iPad test.)
        XCTAssertTrue(
            app.descendants(matching: .any)["Console wall"].waitForExistence(timeout: 5),
            "Compact width must keep the pinned strip.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.descendants(matching: .any)["Console split pane"].exists)

        // Unfold rehearsal: regular width via rotation.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.descendants(matching: .any)["Console split pane"].waitForExistence(timeout: 10),
            "Landscape (regular width) must switch to the split layout.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.descendants(matching: .any)["Console strip"].exists)

        // Session preserved across the size-class transition: the console
        // pane mirrors the durable cook session (step position + live
        // timer). The detail navigation stack itself is view-local and
        // resets to the browser root when the layout swap recreates it —
        // the acceptance criterion is session state, not stack journey.
        let currentStepCard = app.descendants(matching: .any)["Console current step"]
        XCTAssertTrue(
            currentStepCard.waitForExistence(timeout: 5),
            "Console lost the active session across rotation.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            currentStepCard.label.contains("Fluff and rest."),
            "Console lost the persisted step position across rotation.\n\(currentStepCard.label)"
        )
        XCTAssertTrue(app.buttons["Pause timer"].exists)
        // Detail stack reset to browser root: the recipe row is back.
        XCTAssertTrue(app.buttons["Fold Rice"].exists)

        // Fold back: strip returns, split pane goes away, session intact.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            app.descendants(matching: .any)["Console wall"].waitForExistence(timeout: 10),
            "Returning to compact width must restore the strip.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.descendants(matching: .any)["Console split pane"].exists)
        XCTAssertTrue(
            currentStepCard.waitForExistence(timeout: 5)
                && currentStepCard.label.contains("Fluff and rest."),
            "Session position lost after folding back to compact.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["Pause timer"].exists)
    }

    private func createTwoStepRecipe(
        title: String,
        secondStep: String = "Serve warm.",
        timerMinutes: String? = nil
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
        tapWhenHittable(app.buttons["Add Step"], scrolling: form)
        enterText(secondStep, in: app.textViews["Step 2"], form: form)
        dismissKeyboard()
        if let timerMinutes {
            enterText(timerMinutes, in: app.textFields["Step timer 2"], form: form)
            dismissKeyboard()
        }
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
        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 10),
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
