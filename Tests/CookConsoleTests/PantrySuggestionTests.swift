import XCTest

@testable import CookConsole

final class PantrySuggestionTests: XCTestCase {
    func testConservativeAliasesMatchEquivalentNamesOnly() throws {
        let recipe = try makeRecipe(
            title: "Bean Salad",
            ingredients: ["Chickpeas", "Green onions", "Fresh basil"]
        )

        let suggestion = PantrySuggestionEngine.rank(
            recipes: [recipe],
            pantryNames: ["garbanzo beans", "scallions", "dried basil"],
            stapleNames: []
        )[0]

        XCTAssertEqual(suggestion.matchedIngredientNames, ["Chickpeas", "Green onions"])
        XCTAssertEqual(suggestion.missingIngredientNames, ["Fresh basil"])
        XCTAssertFalse(suggestion.isCompleteMatch)
    }

    func testEmptyPantryRanksByVisibleConfiguredStaplesThenMissingCount() throws {
        let toast = try makeRecipe(title: "Toast", ingredients: ["Bread", "Salt"])
        let saltedWater = try makeRecipe(title: "Salt Water", ingredients: ["Water", "Salt"])

        let suggestions = PantrySuggestionEngine.rank(
            recipes: [toast, saltedWater],
            pantryNames: [],
            stapleNames: ["Salt"]
        )

        XCTAssertEqual(suggestions.map(\.recipe.title), ["Salt Water", "Toast"])
        XCTAssertEqual(suggestions[0].stapleIngredientNames, ["Salt"])
        XCTAssertEqual(suggestions[0].coverage, 0.5, accuracy: 0.001)
        XCTAssertEqual(suggestions[0].missingIngredientNames, ["Water"])
        XCTAssertEqual(
            PantrySuggestionEngine.quantityDisclaimer,
            "Name matches do not confirm that you have enough quantity. Check amounts before cooking."
        )
    }

    func testCompleteMatchesRankBeforePartialMatches() throws {
        let complete = try makeRecipe(title: "Pasta", ingredients: ["Pasta", "Salt"])
        let partial = try makeRecipe(title: "Pasta Primavera", ingredients: ["Pasta", "Zucchini", "Salt"])

        let suggestions = PantrySuggestionEngine.rank(
            recipes: [partial, complete],
            pantryNames: ["pasta"],
            stapleNames: ["salt"]
        )

        XCTAssertEqual(suggestions.map(\.recipe.title), ["Pasta", "Pasta Primavera"])
        XCTAssertTrue(suggestions[0].isCompleteMatch)
        XCTAssertEqual(suggestions[1].missingIngredientNames, ["Zucchini"])
    }

    func testPantryItemsPersistAcrossDatabaseReopenAndCanBeRemoved() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cook-console-pantry-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        do {
            let database = try RecipeDatabase.make(at: url.path)
            let repository = PantryRepository(database: database)
            _ = try repository.add(name: "  Garbanzo Beans  ", kind: .onHand)
            _ = try repository.add(name: "Kosher salt", kind: .staple)
        }

        do {
            let database = try RecipeDatabase.make(at: url.path)
            let repository = PantryRepository(database: database)
            XCTAssertEqual(try repository.fetch(kind: .onHand).map(\.name), ["Garbanzo Beans"])
            XCTAssertTrue(try repository.fetch(kind: .staple).map(\.name).contains("Kosher salt"))

            let item = try XCTUnwrap(repository.fetch(kind: .onHand).first)
            XCTAssertTrue(try repository.remove(id: item.id))
            XCTAssertTrue(try repository.fetch(kind: .onHand).isEmpty)
        }
    }

    func testDefaultStaplesSeedOnceAndStayRemovedWhenConfigured() throws {
        let repository = PantryRepository(database: try RecipeDatabase.makeInMemory())
        try repository.seedDefaultStaplesIfNeeded()
        XCTAssertEqual(
            Set(try repository.fetch(kind: .staple).map(\.name)),
            Set(PantrySuggestionEngine.defaultStaples)
        )

        let salt = try XCTUnwrap(repository.fetch(kind: .staple).first { $0.name == "Salt" })
        XCTAssertTrue(try repository.remove(id: salt.id))
        try repository.seedDefaultStaplesIfNeeded()

        XCTAssertFalse(try repository.fetch(kind: .staple).map(\.name).contains("Salt"))
    }

    func testSuggestionsUseLatestEditedRecipeIngredients() throws {
        let database = try RecipeDatabase.makeInMemory()
        let recipes = RecipeRepository(database: database)
        let pantry = PantryRepository(database: database)
        let original = try makeRecipe(title: "Soup", ingredients: ["Stock"])
        try recipes.create(original)
        _ = try pantry.add(name: "Stock", kind: .onHand)

        XCTAssertTrue(try pantry.suggestions(for: recipes.fetchAll()).first?.isCompleteMatch == true)

        let edited = try Recipe(
            id: original.id,
            title: original.title,
            servings: original.servings,
            ingredients: [try Ingredient(name: "Miso", amount: 1, unit: .tablespoon)],
            steps: original.steps
        )
        try recipes.update(edited)

        let suggestion = try pantry.suggestions(for: recipes.fetchAll())[0]
        XCTAssertFalse(suggestion.isCompleteMatch)
        XCTAssertEqual(suggestion.missingIngredientNames, ["Miso"])
    }

    private func makeRecipe(title: String, ingredients: [String]) throws -> Recipe {
        try Recipe(
            title: title,
            servings: 2,
            ingredients: try ingredients.map {
                try Ingredient(name: $0, amount: 1, unit: .each)
            },
            steps: [try RecipeStep(instruction: "Cook.")]
        )
    }
}
