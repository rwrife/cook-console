import XCTest

@testable import CookConsole

final class ConsoleLayoutTests: XCTestCase {
    func testLayoutIsTotalFunctionOfSizeClassInputOnly() {
        XCTAssertEqual(
            ConsoleLayout(input: .compact),
            .compactStrip
        )
        XCTAssertEqual(
            ConsoleLayout(input: .regular),
            .splitView
        )
    }

    func testInputCarriesNoTopologyBeyondSizeClass() {
        // The input enum must stay a pure size-class signal: no device,
        // geometry, or posture cases may ever reach layout selection
        // (PLAN.md Duo seam; enforced by review + this exhaustive switch).
        let allInputs: [ConsoleLayoutInput] = [.compact, .regular]
        XCTAssertEqual(allInputs.count, 2)
        for input in allInputs {
            switch input {
            case .compact, .regular:
                break
            }
        }
    }

    func testLayoutRawValuesAreStableForDocumentation() {
        XCTAssertEqual(ConsoleLayout.compactStrip.rawValue, "compactStrip")
        XCTAssertEqual(ConsoleLayout.splitView.rawValue, "splitView")
    }
}

final class ConsoleSnapshotTests: XCTestCase {
    func testIdleWhenNoSession() throws {
        let recipe = try Fixture.recipe()
        let snapshot = ConsoleSnapshot.snapshot(recipe: recipe, session: nil, timers: [])
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertTrue(snapshot.activeTimers.isEmpty)
    }

    func testIdleWhenSessionFinished() throws {
        let recipe = try Fixture.recipe()
        let ended = Fixture.session(currentStepIndex: 1, status: .completed)
        let snapshot = ConsoleSnapshot.snapshot(recipe: recipe, session: ended, timers: [])
        XCTAssertEqual(snapshot.status, .idle)
    }

    func testCurrentNextAndLastStepBehavior() throws {
        let recipe = try Fixture.recipe()
        let first = ConsoleSnapshot.snapshot(
            recipe: recipe,
            session: Fixture.session(currentStepIndex: 0),
            timers: []
        )
        guard case let .cooking(title, current, next) = first.status else {
            return XCTFail("expected cooking status, got \(first.status)")
        }
        XCTAssertEqual(title, "Console Soup")
        XCTAssertEqual(current, ConsoleSnapshot.ActiveStep(number: 1, instruction: "Simmer gently."))
        XCTAssertEqual(next, ConsoleSnapshot.ActiveStep(number: 2, instruction: "Serve warm."))

        let last = ConsoleSnapshot.snapshot(
            recipe: recipe,
            session: Fixture.session(currentStepIndex: 1),
            timers: []
        )
        guard case let .cooking(_, currentLast, nextLast) = last.status else {
            return XCTFail("expected cooking status")
        }
        XCTAssertEqual(currentLast.number, 2)
        XCTAssertNil(nextLast)
    }

    func testOutOfRangeStepIndexIsClampedLikeCookMode() throws {
        let recipe = try Fixture.recipe()
        // Recipe edited while cooking: steps removed from 2 to 1.
        let shrunk = try Recipe(
            id: recipe.id,
            title: recipe.title,
            servings: recipe.servings,
            ingredients: recipe.ingredients,
            steps: [recipe.steps[0]],
            tags: recipe.tags
        )
        let snapshot = ConsoleSnapshot.snapshot(
            recipe: shrunk,
            session: Fixture.session(currentStepIndex: 5),
            timers: []
        )
        guard case let .cooking(_, current, next) = snapshot.status else {
            return XCTFail("expected clamped cooking status")
        }
        XCTAssertEqual(current.number, 1)
        XCTAssertNil(next)
    }

    func testOnlyRunningAndPausedTimersReachTheWall() throws {
        let recipe = try Fixture.recipe()
        let timers = [
            Fixture.timer(status: .running),
            Fixture.timer(status: .paused),
            Fixture.timer(status: .cancelled),
            Fixture.timer(status: .completed),
        ]
        let snapshot = ConsoleSnapshot.snapshot(
            recipe: recipe,
            session: Fixture.session(currentStepIndex: 0),
            timers: timers
        )
        XCTAssertEqual(Set(snapshot.activeTimers.map(\.status)), [.running, .paused])
    }

    func testIdleRecipeStillReportsActiveTimers() throws {
        // Defensive: timers without a mirror session must never be dropped
        // silently from the snapshot's wall data even though status is idle.
        let snapshot = ConsoleSnapshot.snapshot(
            recipe: nil,
            session: nil,
            timers: [Fixture.timer(status: .running)]
        )
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(snapshot.activeTimers.count, 1)
    }

    private enum Fixture {
        static func recipe() throws -> Recipe {
            try Recipe(
                title: "Console Soup",
                servings: 2,
                ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
                steps: [
                    try RecipeStep(instruction: "Simmer gently."),
                    try RecipeStep(instruction: "Serve warm."),
                ]
            )
        }

        static func session(
            currentStepIndex: Int,
            status: CookSessionStatus = .active
        ) -> CookSession {
            CookSession(
                id: UUID(),
                recipeID: UUID(),
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: status == .active ? nil : Date(timeIntervalSince1970: 200),
                status: status,
                currentStepIndex: currentStepIndex
            )
        }

        static func timer(status: CookTimerStatus) -> CookTimer {
            CookTimer(
                id: UUID(),
                recipeID: UUID(),
                stepID: UUID(),
                cookSessionID: UUID(),
                stepName: "Step 1: Simmer gently.",
                originalDuration: 600,
                status: status,
                startedAt: Date(timeIntervalSince1970: 100),
                deadline: Date(timeIntervalSince1970: 700),
                remainingWhenPaused: status == .paused ? 300 : nil,
                completedAt: status == .completed ? Date(timeIntervalSince1970: 650) : nil,
                scheduleGeneration: 1
            )
        }
    }
}
