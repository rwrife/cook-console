import XCTest

@testable import CookConsole

final class CookSessionRepositoryTests: XCTestCase {
    func testCompleteAndAbandonArePersistedAsTerminalOutcomes() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let recipe = try makeRecipe()
        try repository.create(recipe)
        let completed = try repository.beginCook(
            for: recipe.id,
            at: Date(timeIntervalSince1970: 1_000)
        )
        let completedAt = Date(timeIntervalSince1970: 3_000)
        try repository.endCook(sessionID: completed.id, as: .completed, at: completedAt)
        let abandoned = try repository.beginCook(
            for: recipe.id,
            at: Date(timeIntervalSince1970: 3_500)
        )
        let abandonedAt = Date(timeIntervalSince1970: 4_000)
        try repository.endCook(sessionID: abandoned.id, as: .abandoned, at: abandonedAt)

        let sessions = try repository.fetchCookSessions(for: recipe.id)
        XCTAssertEqual(sessions.map(\.status), [.completed, .abandoned])
        XCTAssertEqual(sessions.map(\.endedAt), [completedAt, abandonedAt])
    }

    func testCookPositionPersistsWhileSessionRemainsActive() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let recipe = try makeRecipe()
        try repository.create(recipe)
        let session = try repository.beginCook(for: recipe.id)

        try repository.updateCookPosition(sessionID: session.id, to: 1)

        let stored = try XCTUnwrap(repository.fetchCookSessions(for: recipe.id).first)
        XCTAssertEqual(stored.currentStepIndex, 1)
        XCTAssertEqual(stored.status, .active)
        XCTAssertNil(stored.endedAt)
    }

    func testBeginCookPersistsActiveSessionAndReentryResumesIt() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let recipe = try makeRecipe()
        try repository.create(recipe)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = try repository.beginCook(for: recipe.id, at: start)
        let resumed = try repository.beginCook(
            for: recipe.id,
            at: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(resumed, first)
        XCTAssertEqual(first.recipeID, recipe.id)
        XCTAssertEqual(first.startedAt, start)
        XCTAssertEqual(first.status, .active)
        XCTAssertEqual(try repository.fetchCookSessions(for: recipe.id), [first])
    }

    func testEditingRecipeToFewerStepsDurablyClampsActivePosition() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let original = try makeRecipe()
        try repository.create(original)
        let session = try repository.beginCook(for: original.id)
        try repository.updateCookPosition(sessionID: session.id, to: 1)

        let shortened = try Recipe(
            id: original.id,
            title: original.title,
            servings: original.servings,
            ingredients: original.ingredients,
            steps: [original.steps[0]],
            tags: original.tags,
            isFavorite: original.isFavorite
        )
        try repository.update(shortened)

        XCTAssertEqual(
            try repository.fetchCookSessions(for: original.id).first?.currentStepIndex,
            0
        )

        let lengthened = try Recipe(
            id: original.id,
            title: original.title,
            servings: original.servings,
            ingredients: original.ingredients,
            steps: original.steps,
            tags: original.tags,
            isFavorite: original.isFavorite
        )
        try repository.update(lengthened)
        XCTAssertEqual(try repository.beginCook(for: original.id).currentStepIndex, 0)
    }

    private func makeRecipe() throws -> Recipe {
        try Recipe(
            title: "Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [
                try RecipeStep(instruction: "Simmer."),
                try RecipeStep(instruction: "Serve."),
            ]
        )
    }
}
