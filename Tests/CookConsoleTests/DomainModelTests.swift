import Foundation
import XCTest

@testable import CookConsole

final class DomainModelTests: XCTestCase {
    func testRecipeRetainsStableIDsAndDomainValues() throws {
        let recipeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let ingredientID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let stepID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let ingredient = try Ingredient(
            id: ingredientID,
            name: "Flour",
            amount: 1.5,
            unit: .cup
        )
        let step = try RecipeStep(
            id: stepID,
            instruction: "Bake until golden.",
            timerDuration: 1_800
        )

        let recipe = try Recipe(
            id: recipeID,
            title: "Bread",
            servings: 8,
            ingredients: [ingredient],
            steps: [step],
            tags: [" Baking ", "vegetarian", "baking"],
            isFavorite: true
        )

        XCTAssertEqual(recipe.id, recipeID)
        XCTAssertEqual(recipe.ingredients.first?.id, ingredientID)
        XCTAssertEqual(recipe.steps.first?.id, stepID)
        XCTAssertEqual(recipe.steps.first?.timerDuration, 1_800)
        XCTAssertEqual(recipe.tags, ["Baking", "vegetarian"])
        XCTAssertTrue(recipe.isFavorite)
    }

    func testIngredientRejectsBlankNameAndInvalidAmounts() {
        XCTAssertThrowsError(try Ingredient(name: " ", amount: 1, unit: .gram))
        for amount: Double in [0, -1, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try Ingredient(name: "Salt", amount: amount, unit: .gram))
        }
    }

    func testStepRejectsBlankInstructionAndInvalidTimer() {
        XCTAssertThrowsError(try RecipeStep(instruction: " "))
        for duration: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try RecipeStep(instruction: "Wait.", timerDuration: duration)
            )
        }
    }

    func testRecipeRejectsInvalidRequiredValues() throws {
        let ingredient = try Ingredient(name: "Salt", amount: 1, unit: .teaspoon)
        let step = try RecipeStep(instruction: "Stir.")

        XCTAssertThrowsError(
            try Recipe(title: " ", servings: 2, ingredients: [ingredient], steps: [step])
        )
        for servings: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try Recipe(title: "Soup", servings: servings, ingredients: [ingredient], steps: [step])
            )
        }
        XCTAssertThrowsError(
            try Recipe(title: "Soup", servings: 2, ingredients: [], steps: [step])
        )
        XCTAssertThrowsError(
            try Recipe(title: "Soup", servings: 2, ingredients: [ingredient], steps: [])
        )
    }

    func testUnitsExposeStableStorageSymbols() {
        XCTAssertEqual(IngredientUnit.teaspoon.symbol, "tsp")
        XCTAssertEqual(IngredientUnit.tablespoon.symbol, "tbsp")
        XCTAssertEqual(IngredientUnit.cup.symbol, "cup")
        XCTAssertEqual(IngredientUnit.gram.symbol, "g")
        XCTAssertEqual(IngredientUnit.each.symbol, "each")
    }
}
