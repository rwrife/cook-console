import XCTest

/// Issue #7 coverage: VoiceOver semantics (meaningful labels/values, not
/// bare "button"), Dynamic Type at the largest accessibility size on the
/// main test device, hit-target sizes on the cook/console surfaces, and
/// the timer-state accessibility value machine as rendered.
///
/// VoiceOver itself cannot be driven from XCUITest, so the narration
/// contract is asserted through the AX attributes VoiceOver consumes:
/// `label` and `value`. Screenshots of the AX-size layouts attach to the
/// xcresult (kept with lifetime .keepAlways) — that artifact is the
/// committed visual evidence referenced from docs/ISSUE-7-VERIFICATION.md.
final class AccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(flags: [String]) {
        app = XCUIApplication()
        app.launchArguments = flags
        app.launch()
    }

    // MARK: VoiceOver semantics

    /// Timer state must be spoken as state, not read off a digit clock:
    /// start a step timer, pause it, and prove the remaining-time element's
    /// accessibility VALUE says "… remaining, paused" (word-phrased, no
    /// "mm:ss"), which is what VoiceOver dictates on rotor focus.
    func testTimerStateIsNarratedAsWordsNotClockDigits() {
        launch(flags: ["-ui-testing-reset", "-ui-testing-staggered-timer-fixture"])
        app.buttons["Staggered Timer Fixture"].tap()
        app.buttons["Cook"].tap()

        let start = app.buttons["Start step timer"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        // The start control narrates its duration in words.
        XCTAssertTrue(
            start.label.contains("20 seconds") || start.label.contains("minutes"),
            "Start timer label must speak the duration: \(start.label)"
        )
        start.tap()

        let pause = app.buttons["Pause timer"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()

        // The countdown element carries the spoken value + state word.
        let remainingQuery = app.descendants(matching: .any)
            .matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "Timer remaining")
            ).firstMatch
        XCTAssertTrue(remainingQuery.waitForExistence(timeout: 5))
        let value = remainingQuery.value as? String ?? ""
        XCTAssertTrue(
            value.contains("remaining, paused"),
            "Paused timer must narrate '…, paused' — got '\(value)'"
        )
        XCTAssertFalse(value.contains(":"), "Spoken value must not use mm:ss: \(value)")
        XCTAssertTrue(app.buttons["Resume timer"].exists)
    }

    /// Library rows must speak title AND tags (label + value), and the
    /// detail servings readout must speak "Servings, <n>".
    func testLibraryAndDetailNarrationIsMeaningful() throws {
        launch(flags: ["-ui-testing-reset", "-ui-testing-a11y-recipe-fixture"])
        let row = app.descendants(matching: .any)["Recipe row A11y Soup"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(row.label, "A11y Soup")
        XCTAssertTrue(
            row.value as? String == "weeknight" || (row.value as? String)?.contains("weeknight") == true,
            "Library row must speak tags as value: \(String(describing: row.value))"
        )

        row.tap()
        XCTAssertTrue(app.navigationBars["A11y Soup"].waitForExistence(timeout: 5))
        let servings = app.staticTexts.matching(
            NSPredicate(format: "label == 'Servings'")
        ).firstMatch
        XCTAssertTrue(servings.waitForExistence(timeout: 3))
        XCTAssertFalse((servings.value as? String)?.isEmpty ?? true,
                       "Servings readout must carry a spoken value.")
    }
    // MARK: Hit targets (>= 44pt)

    /// Every interactive control on the cook-mode timer wall and step
    /// pager must offer at least the 44x44pt minimum target.
    func testCookModeControlsMeetMinimumHitTargets() {
        launch(flags: ["-ui-testing-reset", "-ui-testing-staggered-timer-fixture"])
        app.buttons["Staggered Timer Fixture"].tap()
        app.buttons["Cook"].tap()

        let pager = app.buttons["Next step"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        assertAtLeast44(pager, name: "Next step pager")

        let start = app.buttons["Start step timer"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        assertAtLeast44(start, name: "Start step timer")

        start.tap()
        for name in ["Pause timer", "Extend timer by 2 minutes", "Extend timer by 5 minutes", "Cancel timer"] {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(name)\n\(app.debugDescription)")
            assertAtLeast44(button, name: name)
        }
    }

    private func assertAtLeast44(_ element: XCUIElement, name: String, file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        // 0.01pt tolerance for pixel-grid rounding only.
        XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.01, "\(name) width \(frame.width) < 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.01, "\(name) height \(frame.height) < 44pt", file: file, line: line)
    }

    // MARK: Largest Dynamic Type

    /// Accessibility XXXL on the main device: the step counter, the
    /// current step, and the pager controls must all remain reachable
    /// (scrolling allowed; the pager is bottom-pinned by design).
    /// Screenshots attach to the xcresult as the committed evidence.
    func testLargestAccessibilityTextKeepsCookControlsReachable() {
        launch(flags: [
            "-ui-testing-reset",
            "-ui-testing-staggered-timer-fixture",
            "-ui-testing-report-size-category",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        // Prove the Dynamic Type override actually resolved — a wrong
        // launch constant would otherwise silently test the default size.
        let readout = app.descendants(matching: .any)["Size category readout"]
        XCTAssertTrue(
            readout.waitForExistence(timeout: 10),
            "Size-category readout never mounted.\n\(app.debugDescription)"
        )
        // The readout renders the resolved ContentSizeMode description.
        // On the iOS 26 SDK that is the abbreviation form (default "L",
        // accessibility sizes prefixed "A"), so "AXXXL" proves the
        // Accessibility-XXXL launch override resolved. Accept the full
        // UICTContentSizeCategory wording too in case a future SDK
        // changes the description format.
        let resolved = readout.label.lowercased()
        XCTAssertTrue(
            resolved.contains("axxxl") || resolved.contains("accessibility"),
            "Resolved size category must be an accessibility category: \(readout.label)"
        )

        app.buttons["Staggered Timer Fixture"].tap()
        app.buttons["Cook"].tap()

        let stepCounter = app.staticTexts["Step 1 of 2"]
        XCTAssertTrue(
            stepCounter.waitForExistence(timeout: 10),
            "Step counter unreachable at AX XXXL.\n\(app.debugDescription)"
        )
        attachScreenshot(named: "cook-ax-xxxl-entry")

        // The start-timer control lives in the scrollable column; at XXXL
        // it may start below the fold — scroll to it, then prove the hit
        // target is real. The bottom-pinned pager must stay mounted beside
        // the scrolled column.
        let start = app.buttons["Start step timer"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 10),
            "Start step timer never mounted at AX XXXL.\n\(app.debugDescription)"
        )
        scrollUntilHittable(start)
        XCTAssertTrue(app.buttons["Next step"].isHittable,
                      "The bottom pager must stay reachable at AX XXXL.")
        attachScreenshot(named: "cook-ax-xxxl-controls")
    }

    /// Bounded scroll-until-hittable for the cook-mode ScrollView (iOS 26
    /// List bridges to CollectionView; the cook column is a ScrollView).
    private func scrollUntilHittable(_ element: XCUIElement) {
        if element.isHittable { return }
        let scroller: XCUIElement
        if app.scrollViews.firstMatch.waitForExistence(timeout: 3) {
            scroller = app.scrollViews.firstMatch
        } else if app.collectionViews.firstMatch.waitForExistence(timeout: 2) {
            scroller = app.collectionViews.firstMatch
        } else {
            scroller = app.tables.firstMatch
            XCTAssertTrue(scroller.waitForExistence(timeout: 3), app.debugDescription)
        }
        for _ in 0..<10 {
            if element.isHittable { return }
            scroller.swipeUp()
        }
        XCTAssertTrue(element.isHittable,
                      "Element never became hittable after bounded scrolling.\n\(app.debugDescription)")
    }

    private func attachScreenshot(named: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
