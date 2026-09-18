import GRDB
import XCTest

@testable import CookConsole

final class RecipeRepositoryTests: XCTestCase {
    func testLibraryTagFilterMatchesWholeTagCaseInsensitively() throws {
        let repository = try makeRepository()
        let weekend = try makeRecipe(title: "Weekend Bread")
        let quick = try Recipe(
            title: "Quick Toast",
            servings: 1,
            ingredients: [try Ingredient(name: "Bread", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Toast.")],
            tags: ["quick"]
        )
        try repository.create(weekend)
        try repository.create(quick)

        XCTAssertEqual(try repository.fetchLibrary(selectedTag: "WEEKEND"), [weekend])
    }

    func testLibraryTitleSearchIsCaseInsensitiveAndTrimsWhitespace() throws {
        let repository = try makeRepository()
        let soup = try makeRecipe(title: "Tomato Soup")
        let bread = try makeRecipe(title: "Bread")
        try repository.create(soup)
        try repository.create(bread)

        XCTAssertEqual(try repository.fetchLibrary(searchText: "  SOUP  "), [soup])
    }

    func testLibrarySortsFavoritesFirstThenMostRecentlyCooked() throws {
        let repository = try makeRepository()
        let olderFavorite = try makeRecipe(title: "Older favorite", favorite: true)
        let newerFavorite = try makeRecipe(title: "Newer favorite", favorite: true)
        let recentlyCooked = try makeRecipe(title: "Recently cooked")
        let neverCooked = try makeRecipe(title: "Never cooked")
        for recipe in [olderFavorite, newerFavorite, recentlyCooked, neverCooked] {
            try repository.create(recipe)
        }
        for (recipe, timestamp) in [
            (olderFavorite, 100.0),
            (newerFavorite, 200.0),
            (recentlyCooked, 300.0),
        ] {
            let date = Date(timeIntervalSince1970: timestamp)
            let session = try repository.beginCook(for: recipe.id, at: date)
            try repository.endCook(sessionID: session.id, as: .completed, at: date)
        }

        XCTAssertEqual(
            try repository.fetchLibrary().map(\.id),
            [newerFavorite.id, olderFavorite.id, recentlyCooked.id, neverCooked.id]
        )
    }

    func testVersionedMigrationsBuildExpectedSchemaInMemory() throws {
        let database = try RecipeDatabase.makeInMemory()

        let migrationIDs = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }
        let tables = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }

        XCTAssertEqual(migrationIDs, [
            "v1_create_recipe_core",
            "v2_add_recipe_favorite",
            "v3_create_cook_sessions",
            "v4_create_step_timers",
            "v5_timer_invariants_and_completion_queue",
            "v6_timer_schedule_generation",
        ])
        let timerColumns = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('cook_timers') ORDER BY name"
            )
        }
        XCTAssertTrue(timerColumns.contains("schedule_generation"))
        XCTAssertTrue(tables.contains("recipes"))
        XCTAssertTrue(tables.contains("ingredients"))
        XCTAssertTrue(tables.contains("recipe_steps"))
        XCTAssertTrue(tables.contains("recipe_tags"))
        XCTAssertTrue(tables.contains("cook_sessions"))
        XCTAssertTrue(tables.contains("cook_timers"))
        XCTAssertTrue(tables.contains("timer_events"))
        XCTAssertTrue(tables.contains("timer_completion_alerts"))
    }

    func testV1DatabaseUpgradesToLatestWithoutLosingRows() throws {
        let database = try DatabaseQueue()
        let migrator = RecipeDatabase.makeMigrator()
        try migrator.migrate(database, upTo: "v1_create_recipe_core")
        let recipeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let ingredientID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let stepID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings) VALUES (?, ?, ?)",
                arguments: [recipeID.uuidString, "Legacy Soup", 3]
            )
            try db.execute(
                sql: "INSERT INTO ingredients (id, recipe_id, position, name, amount, unit) VALUES (?, ?, 0, ?, ?, ?)",
                arguments: [ingredientID.uuidString, recipeID.uuidString, "Stock", 2, "cup"]
            )
            try db.execute(
                sql: "INSERT INTO recipe_steps (id, recipe_id, position, instruction, timer_duration) VALUES (?, ?, 0, ?, ?)",
                arguments: [stepID.uuidString, recipeID.uuidString, "Simmer.", 600]
            )
            try db.execute(
                sql: "INSERT INTO recipe_tags (recipe_id, position, name) VALUES (?, 0, ?)",
                arguments: [recipeID.uuidString, "legacy"]
            )
        }

        try migrator.migrate(database)

        let stored = try RecipeRepository(database: database).fetch(id: recipeID)
        XCTAssertEqual(stored?.title, "Legacy Soup")
        XCTAssertEqual(stored?.ingredients.first?.id, ingredientID)
        XCTAssertEqual(stored?.steps.first?.id, stepID)
        XCTAssertEqual(stored?.tags, ["legacy"])
        XCTAssertEqual(stored?.isFavorite, false)
    }

    func testSchemaRejectsInvalidRecipeScalars() throws {
        let database = try RecipeDatabase.makeInMemory()

        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, " ", 2, false]
            )
        })
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Soup", 2, 2]
            )
        })
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Soup", 0, false]
            )
        })
    }

    func testSchemaRejectsFoundationWhitespaceOnlyTextForEveryStoredField() throws {
        let database = try RecipeDatabase.makeInMemory()
        let recipeID = UUID()
        let foundationWhitespace = """
            \u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{0085}\u{00a0}\u{1680}
            \u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}
            \u{2028}\u{2029}\u{202f}\u{205f}\u{3000}
            """

        XCTAssertTrue(
            foundationWhitespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, foundationWhitespace, 2, false]
            )
        })

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
                arguments: [recipeID.uuidString, "Soup", 2, false]
            )
        }
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO ingredients (id, recipe_id, position, name, amount, unit) VALUES (?, ?, 0, ?, 1, 'cup')",
                arguments: [UUID().uuidString, recipeID.uuidString, foundationWhitespace]
            )
        })
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipe_steps (id, recipe_id, position, instruction) VALUES (?, ?, 0, ?)",
                arguments: [UUID().uuidString, recipeID.uuidString, foundationWhitespace]
            )
        })
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: "INSERT INTO recipe_tags (recipe_id, position, name) VALUES (?, 0, ?)",
                arguments: [recipeID.uuidString, foundationWhitespace]
            )
        })
    }

    func testCreateAndFetchRoundTripsEveryDomainValue() throws {
        let repository = try makeRepository()
        let recipe = try makeRecipe(title: "Bread", favorite: true)

        try repository.create(recipe)

        XCTAssertEqual(try repository.fetch(id: recipe.id), recipe)
    }

    func testFetchAllSortsCaseInsensitivelyByTitle() throws {
        let repository = try makeRepository()
        let zebra = try makeRecipe(title: "zebra")
        let apple = try makeRecipe(title: "Apple")
        try repository.create(zebra)
        try repository.create(apple)

        XCTAssertEqual(try repository.fetchAll().map(\.title), ["Apple", "zebra"])
    }

    func testUpdateAtomicallyReplacesRecipeAndChildren() throws {
        let repository = try makeRepository()
        let original = try makeRecipe(title: "Bread")
        try repository.create(original)
        let replacement = try Recipe(
            id: original.id,
            title: "Favorite Bread",
            servings: 12,
            ingredients: [try Ingredient(name: "Rye flour", amount: 800, unit: .gram)],
            steps: [try RecipeStep(instruction: "Bake.", timerDuration: 2_400)],
            tags: ["rye"],
            isFavorite: true
        )

        try repository.update(replacement)

        XCTAssertEqual(try repository.fetch(id: original.id), replacement)
    }

    func testDeleteCascadesChildrenAndReportsWhetherRecipeExisted() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repository = RecipeRepository(database: database)
        let recipe = try makeRecipe(title: "Bread")
        try repository.create(recipe)

        XCTAssertTrue(try repository.delete(id: recipe.id))
        XCTAssertFalse(try repository.delete(id: recipe.id))
        XCTAssertNil(try repository.fetch(id: recipe.id))
        let childCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients")!
                + Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipe_steps")!
                + Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipe_tags")!
        }
        XCTAssertEqual(childCount, 0)
    }

    func testCreateRollsBackParentWhenAChildInsertFails() throws {
        let repository = try makeRepository()
        let existing = try makeRecipe(title: "First")
        try repository.create(existing)
        let conflicting = try Recipe(
            title: "Second",
            servings: 2,
            ingredients: [try Ingredient(
                id: existing.ingredients[0].id,
                name: "Collision",
                amount: 1,
                unit: .cup
            )],
            steps: [try RecipeStep(instruction: "Mix.")]
        )

        XCTAssertThrowsError(try repository.create(conflicting))
        XCTAssertNil(try repository.fetch(id: conflicting.id))
        XCTAssertEqual(try repository.fetchAll(), [existing])
    }

    func testUpdateRollsBackParentAndChildrenWhenReplacementChildInsertFails() throws {
        let repository = try makeRepository()
        let original = try makeRecipe(title: "Original")
        let other = try makeRecipe(title: "Other")
        try repository.create(original)
        try repository.create(other)
        let invalidReplacement = try Recipe(
            id: original.id,
            title: "Should Roll Back",
            servings: 12,
            ingredients: [try Ingredient(
                id: other.ingredients[0].id,
                name: "Conflicting flour",
                amount: 4,
                unit: .cup
            )],
            steps: [try RecipeStep(instruction: "Replace.")],
            tags: ["replacement"],
            isFavorite: true
        )

        XCTAssertThrowsError(try repository.update(invalidReplacement))
        XCTAssertEqual(try repository.fetch(id: original.id), original)
        XCTAssertEqual(try repository.fetch(id: other.id), other)
    }

    func testDuplicateCreateAndMissingUpdateAreRejected() throws {
        let repository = try makeRepository()
        let recipe = try makeRecipe(title: "Bread")
        try repository.create(recipe)

        XCTAssertThrowsError(try repository.create(recipe))
        let missing = try makeRecipe(title: "Missing")
        XCTAssertThrowsError(try repository.update(missing)) { error in
            XCTAssertEqual(error as? RecipeRepositoryError, .notFound(missing.id))
        }
    }

    private func makeRepository() throws -> RecipeRepository {
        RecipeRepository(database: try RecipeDatabase.makeInMemory())
    }

    private func makeRecipe(title: String, favorite: Bool = false) throws -> Recipe {
        try Recipe(
            title: title,
            servings: 4,
            ingredients: [try Ingredient(name: "Flour", amount: 2.5, unit: .cup)],
            steps: [try RecipeStep(instruction: "Rest.", timerDuration: 900)],
            tags: ["baking", "weekend"],
            isFavorite: favorite
        )
    }
}
