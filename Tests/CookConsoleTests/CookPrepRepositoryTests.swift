import Foundation
import XCTest
@testable import CookConsole

final class CookPrepRepositoryTests: XCTestCase {
    func testPrepRejectsInvalidServingsAndTerminalSessions() throws {
        for servings in [0, -1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try CookPrep(servings: servings))
        }
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let recipe = try Recipe(title: "Soup", servings: 2,
            ingredients: [Ingredient(name: "Stock", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Simmer.")])
        try repository.create(recipe)
        let first = try repository.beginCook(for: recipe.id)
        XCTAssertNil(try repository.cookPrep(sessionID: first.id))
        let prep = try CookPrep(servings: 3)
        try repository.saveCookPrep(prep, sessionID: first.id)
        try repository.endCook(sessionID: first.id, as: .completed)
        XCTAssertThrowsError(try repository.saveCookPrep(prep, sessionID: first.id))
        let second = try repository.beginCook(for: recipe.id)
        XCTAssertNil(try repository.cookPrep(sessionID: second.id))
        XCTAssertThrowsError(try repository.saveCookPrep(prep, sessionID: UUID()))
    }

    func testPrepSurvivesRepositoryRecreationWithoutAdvancingStep() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repository = RecipeRepository(database: database)
        let recipe = try Recipe(title: "Prep Soup", servings: 2,
            ingredients: [Ingredient(name: "Carrots, chopped", amount: 2, unit: .each)],
            steps: [RecipeStep(instruction: "Simmer."), RecipeStep(instruction: "Serve.")])
        try repository.create(recipe)
        let session = try repository.beginCook(for: recipe.id)
        let prep = try CookPrep(servings: 4, checkedIngredientIDs: [recipe.ingredients[0].id],
            equipment: "Pot, knife", swapped: true)
        try repository.saveCookPrep(prep, sessionID: session.id)
        let reopened = RecipeRepository(database: database)
        XCTAssertEqual(try reopened.cookPrep(sessionID: session.id), prep)
        XCTAssertEqual(try reopened.fetchCookSession(id: session.id)?.currentStepIndex, 0)
        XCTAssertEqual(try reopened.beginCook(for: recipe.id).id, session.id)
        XCTAssertEqual(try ScalingEngine.scaledIngredients(for: recipe, targetServings: prep.servings)[0].exactAmount, 4)
    }
}
