#if canImport(SwiftUI)
import XCTest

@testable import CookConsole

@MainActor
final class AppStoreQueryTests: XCTestCase {
    func testSaveAndEndCookReloadUsingActiveComposedQuery() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let matching = try Recipe(
            title: "Quick Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer.")],
            tags: ["QUICK"]
        )
        let titleOnly = try Recipe(
            title: "Slow Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer.")],
            tags: ["weekend"]
        )
        let tagOnly = try Recipe(
            title: "Quick Toast",
            servings: 2,
            ingredients: [try Ingredient(name: "Bread", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Toast.")],
            tags: ["quick"]
        )
        try repository.create(matching)
        try repository.create(titleOnly)
        try repository.create(tagOnly)
        let store = AppStore(repository: repository)
        store.loadLibrary(searchText: "Soup", selectedTag: "QUICK")
        XCTAssertEqual(store.allTags.filter { $0.lowercased() == "quick" }.count, 1)

        try store.save(matching, isNew: false)
        XCTAssertEqual(store.recipes.map(\.id), [matching.id])

        let session = try store.beginCook(for: matching.id)
        try store.endCook(sessionID: session.id, as: .completed)
        XCTAssertEqual(store.recipes.map(\.id), [matching.id])
    }

    func testLaunchAndForegroundReconciliationPresentDurableCompletionsUntilAcknowledged() async throws {
        let database = try RecipeDatabase.makeInMemory()
        let recipes = RecipeRepository(database: database)
        let recipe = try Recipe(
            title: "Timed Rice",
            servings: 2,
            ingredients: [try Ingredient(name: "Rice", amount: 1, unit: .cup)],
            steps: [try RecipeStep(instruction: "Steam.", timerDuration: 10)]
        )
        try recipes.create(recipe)
        let session = try recipes.beginCook(for: recipe.id, at: Date(timeIntervalSince1970: 1_000))
        let clock = AppStoreTestClock(1_000)
        let engine = TimerEngine(
            repository: TimerRepository(database: database),
            notifications: NoopTimerNotificationScheduler(),
            now: { [clock] in clock.date }
        )
        let launchTimer = try engine.start(
            recipeID: recipe.id,
            stepID: recipe.steps[0].id,
            cookSessionID: session.id,
            stepName: "Step 1: Steam.",
            duration: 10
        )
        clock.date = Date(timeIntervalSince1970: 1_011)

        let store = AppStore(repository: recipes, timerEngine: engine)

        XCTAssertEqual(store.completedTimerMessage, "Step 1: Steam. timer finished.")
        XCTAssertEqual(try engine.pendingCompletions().map(\.id), [launchTimer.id])
        store.acknowledgePresentedCompletion()
        store.completionAlertDismissed()
        try await waitForMessage(store, toBe: nil)
        XCTAssertTrue(try engine.pendingCompletions().isEmpty)

        let foregroundTimer = try engine.start(
            recipeID: recipe.id,
            stepID: recipe.steps[0].id,
            cookSessionID: session.id,
            stepName: "Step 1: Steam again.",
            duration: 10
        )
        clock.date = Date(timeIntervalSince1970: 1_022)
        store.reconcileTimers()

        XCTAssertEqual(store.completedTimerMessage, "Step 1: Steam again. timer finished.")
        XCTAssertEqual(try engine.pendingCompletions().map(\.id), [foregroundTimer.id])
        store.acknowledgePresentedCompletion()
        store.completionAlertDismissed()
        try await waitForMessage(store, toBe: nil)
        XCTAssertTrue(try engine.pendingCompletions().isEmpty)
    }

    func testDoubleAcknowledgmentCannotConsumeTheNextQueuedCompletion() async throws {
        let database = try RecipeDatabase.makeInMemory()
        let recipes = RecipeRepository(database: database)
        let recipe = try Recipe(
            title: "Twin Timers",
            servings: 2,
            ingredients: [try Ingredient(name: "Rice", amount: 1, unit: .cup)],
            steps: [
                try RecipeStep(instruction: "Boil.", timerDuration: 10),
                try RecipeStep(instruction: "Rest.", timerDuration: 20),
            ]
        )
        try recipes.create(recipe)
        let session = try recipes.beginCook(for: recipe.id, at: Date(timeIntervalSince1970: 2_000))
        let clock = AppStoreTestClock(2_000)
        let engine = TimerEngine(
            repository: TimerRepository(database: database),
            notifications: NoopTimerNotificationScheduler(),
            now: { [clock] in clock.date }
        )
        let first = try engine.start(
            recipeID: recipe.id,
            stepID: recipe.steps[0].id,
            cookSessionID: session.id,
            stepName: "Step 1: Boil.",
            duration: 10
        )
        let second = try engine.start(
            recipeID: recipe.id,
            stepID: recipe.steps[1].id,
            cookSessionID: session.id,
            stepName: "Step 2: Rest.",
            duration: 20
        )
        clock.date = Date(timeIntervalSince1970: 2_021)
        let store = AppStore(repository: recipes, timerEngine: engine)

        // Both deadlines passed while suspended; exactly one alert shows and
        // both completions remain durably queued in order.
        XCTAssertEqual(store.completedTimerMessage, "Step 1: Boil. timer finished.")
        XCTAssertEqual(try engine.pendingCompletions().map(\.id), [first.id, second.id])

        // The OK action acknowledges exactly one timer even when alert
        // dismissal paths invoke it repeatedly: the presented message clears
        // synchronously, but the second completion stays durably queued and
        // is only presented by the dismissal signal, never consumed here.
        store.acknowledgePresentedCompletion()
        store.acknowledgePresentedCompletion()
        store.acknowledgePresentedCompletion()
        XCTAssertNil(store.completedTimerMessage)
        XCTAssertEqual(try engine.pendingCompletions().map(\.id), [second.id])

        store.completionAlertDismissed()
        // A reconciliation racing the dismissal window must not present
        // mid-animation; only the dismissal-driven advance may.
        store.reconcileTimers()
        XCTAssertNil(store.completedTimerMessage)
        try await waitForMessage(store, toBe: "Step 2: Rest. timer finished.")
        XCTAssertEqual(try engine.pendingCompletions().map(\.id), [second.id])

        store.acknowledgePresentedCompletion()
        store.completionAlertDismissed()
        try await waitForMessage(store, toBe: nil)
        XCTAssertTrue(try engine.pendingCompletions().isEmpty)
    }

    private func waitForMessage(
        _ store: AppStore,
        toBe expected: String?,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.completedTimerMessage != expected, Date() < deadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.completedTimerMessage, expected)
    }
}

private final class AppStoreTestClock: @unchecked Sendable {
    var date: Date

    init(_ timeInterval: TimeInterval) {
        date = Date(timeIntervalSince1970: timeInterval)
    }
}
#endif
