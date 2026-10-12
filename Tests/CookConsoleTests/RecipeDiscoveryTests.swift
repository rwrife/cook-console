import XCTest
@testable import CookConsole

final class RecipeDiscoveryTests: XCTestCase {
    func testStatedDurationDistinguishesUnknownFromZero() throws {
        let stated = try Recipe(
            title: "Quick Eggs",
            servings: 1,
            ingredients: [try Ingredient(name: "Egg", amount: 2, unit: .each)],
            steps: [try RecipeStep(instruction: "Fry.")],
            totalMinutes: 10
        )
        let unknown = try Recipe(
            title: "Unknown Time Stew",
            servings: 1,
            ingredients: [try Ingredient(name: "Beef", amount: 200, unit: .gram)],
            steps: [try RecipeStep(instruction: "Simmer.")],
            totalMinutes: nil
        )

        var filter = RecipeDiscoveryFilter()
        filter.maxMinutes = 30
        XCTAssertTrue(filter.matches(stated))
        XCTAssertFalse(filter.matches(unknown), "Unknown duration must not match 30 minutes or less")
    }

    func testFiveIngredientsOrFewerRuleCountsEveryIngredientRow() throws {
        // Documented rule: every ingredient row counts, including salt/water/repeats.
        let five = try Recipe(
            title: "Five Item Pasta",
            servings: 2,
            ingredients: [
                try Ingredient(name: "Pasta", amount: 200, unit: .gram),
                try Ingredient(name: "Olive oil", amount: 2, unit: .tablespoon),
                try Ingredient(name: "Garlic", amount: 2, unit: .each),
                try Ingredient(name: "Salt", amount: 1, unit: .teaspoon),
                try Ingredient(name: "Cheese", amount: 30, unit: .gram),
            ],
            steps: [try RecipeStep(instruction: "Toss.")]
        )
        let six = try Recipe(
            title: "Six Item Pasta",
            servings: 2,
            ingredients: [
                try Ingredient(name: "Pasta", amount: 200, unit: .gram),
                try Ingredient(name: "Olive oil", amount: 2, unit: .tablespoon),
                try Ingredient(name: "Garlic", amount: 2, unit: .each),
                try Ingredient(name: "Salt", amount: 1, unit: .teaspoon),
                try Ingredient(name: "Cheese", amount: 30, unit: .gram),
                try Ingredient(name: "Black pepper", amount: 0.5, unit: .teaspoon),
            ],
            steps: [try RecipeStep(instruction: "Toss.")]
        )

        var filter = RecipeDiscoveryFilter()
        filter.maxIngredients = 5
        XCTAssertTrue(filter.matches(five))
        XCTAssertFalse(filter.matches(six))
    }

    func testMealTypeMatchesCaseInsensitiveTags() throws {
        let breakfast = try Recipe(
            title: "Oatmeal",
            servings: 1,
            ingredients: [try Ingredient(name: "Oats", amount: 50, unit: .gram)],
            steps: [try RecipeStep(instruction: "Boil.")],
            tags: ["Breakfast", "Comfort"]
        )
        let dinner = try Recipe(
            title: "Soup",
            servings: 1,
            ingredients: [try Ingredient(name: "Broth", amount: 250, unit: .milliliter)],
            steps: [try RecipeStep(instruction: "Heat.")],
            tags: ["Dinner"]
        )

        var filter = RecipeDiscoveryFilter()
        filter.mealType = "breakfast"
        XCTAssertTrue(filter.matches(breakfast))
        XCTAssertFalse(filter.matches(dinner))
    }

    func testDietaryTagsAreMatchesOnlyWithoutUnsupportedClaims() throws {
        let vegan = try Recipe(
            title: "Salad",
            servings: 1,
            ingredients: [try Ingredient(name: "Lettuce", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Wash.")],
            tags: ["vegan"]
        )
        let unstated = try Recipe(
            title: "Apple",
            servings: 1,
            ingredients: [try Ingredient(name: "Apple", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Slice.")],
            tags: []
        )

        var filter = RecipeDiscoveryFilter()
        filter.dietaryTag = "vegan"
        XCTAssertTrue(filter.matches(vegan))
        // Apple is vegan ingredient, but app avoids making unsupported dietary claims.
        XCTAssertFalse(filter.matches(unstated), "Unlabeled recipe must not match dietary filter")
    }

    func testCombinedFiltersWithEditedAndImportedRecipes() throws {
        let recipe = try Recipe(
            title: "Quick Vegan Tacos",
            servings: 2,
            ingredients: [
                try Ingredient(name: "Corn tortilla", amount: 4, unit: .each),
                try Ingredient(name: "Beans", amount: 200, unit: .gram),
                try Ingredient(name: "Salsa", amount: 2, unit: .tablespoon),
            ],
            steps: [try RecipeStep(instruction: "Assemble.")],
            tags: ["Dinner", "vegan"],
            totalMinutes: 15
        )

        var filter = RecipeDiscoveryFilter()
        filter.text = "tacos"
        filter.maxMinutes = 30
        filter.maxIngredients = 5
        filter.mealType = "dinner"
        filter.dietaryTag = "vegan"
        filter.ingredient = "beans"

        XCTAssertTrue(filter.matches(recipe))
        XCTAssertEqual(filter.activeLabels.count, 6)
        XCTAssertTrue(filter.isActive)
    }

    func testBackupImportPreservesDiscoveryMetadataAndOldBackupLeavesDurationUnknown() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repo = RecipeRepository(database: database)
        let service = DataTransferService(database: database, appVersion: "test", now: { Date() })
        let original = try Recipe(
            title: "Edited Veggie Toast",
            servings: 1,
            ingredients: [try Ingredient(name: "Tomato", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Serve.")],
            tags: ["lunch", "vegetarian"],
            totalMinutes: 15
        )
        try repo.create(original)
        var document = try service.exportDocument()
        XCTAssertEqual(document.recipes.first?.totalMinutes, 15)

        // Simulate an edited/imported recipe: replacement carries new time,
        // and library filtering consumes the imported value, not stale index.
        document.recipes[0].totalMinutes = 25
        let preview = try service.preview(document)
        _ = try service.apply(preview)
        var filter = RecipeDiscoveryFilter()
        filter.maxMinutes = 30
        filter.mealType = "lunch"
        XCTAssertEqual(try repo.fetchLibrary(discovery: filter).map(\.id), [original.id])
        XCTAssertEqual(try repo.fetch(id: original.id)?.totalMinutes, 25)

        // Pre-#27 JSON has no totalMinutes key; nil is unknown, not 0.
        document.recipes[0].totalMinutes = nil
        let oldPreview = try service.preview(document)
        _ = try service.apply(oldPreview)
        XCTAssertNil(try repo.fetch(id: original.id)?.totalMinutes)
        XCTAssertTrue(try repo.fetchLibrary(discovery: filter).isEmpty)
    }

    func testRecipeRepositoryPersistsAndFiltersByTotalMinutes() throws {
        let db = try RecipeDatabase.makeInMemory()
        let repo = RecipeRepository(database: db)

        let r1 = try Recipe(
            title: "Express Toast",
            servings: 1,
            ingredients: [try Ingredient(name: "Bread", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Toast.")],
            totalMinutes: 5
        )
        let r2 = try Recipe(
            title: "Slow Braise",
            servings: 4,
            ingredients: [try Ingredient(name: "Beef", amount: 500, unit: .gram)],
            steps: [try RecipeStep(instruction: "Braise.")],
            totalMinutes: 180
        )
        try repo.create(r1)
        try repo.create(r2)

        let fetched = try repo.fetch(id: r1.id)
        XCTAssertEqual(fetched?.totalMinutes, 5)

        var filter = RecipeDiscoveryFilter()
        filter.maxMinutes = 30
        let results = try repo.fetchLibrary(discovery: filter)
        XCTAssertEqual(results.map(\.id), [r1.id])
    }
}
