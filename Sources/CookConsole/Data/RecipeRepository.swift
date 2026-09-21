import Foundation
import GRDB

enum RecipeRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case notFound(UUID)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(id):
            return "No recipe exists with ID \(id.uuidString)."
        case let .corruptData(reason):
            return "Stored recipe data is invalid: \(reason)"
        }
    }
}

final class RecipeRepository {
    /// Exposed for `DataTransferService` (issue #6 backup/restore) — all
    /// access stays local (Foundation + GRDB, zero network).
    let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    func create(_ recipe: Recipe) throws {
        try database.write { db in
            try insert(recipe, into: db)
        }
    }

    func fetch(id: UUID) throws -> Recipe? {
        try database.read { db in
            try fetchRecipe(id: id, from: db)
        }
    }

    func fetchAll() throws -> [Recipe] {
        try database.read { db in
            let identifiers = try String.fetchAll(
                db,
                sql: "SELECT id FROM recipes ORDER BY title COLLATE NOCASE, id"
            )
            return try identifiers.map { identifier in
                guard let id = UUID(uuidString: identifier),
                      let recipe = try fetchRecipe(id: id, from: db)
                else {
                    throw RecipeRepositoryError.corruptData("Recipe ID '\(identifier)' is invalid.")
                }
                return recipe
            }
        }
    }

    func fetchLibrary(
        searchText: String = "",
        selectedTag: String? = nil
    ) throws -> [Recipe] {
        let recipes = try database.read { db in
            let identifiers = try String.fetchAll(
                db,
                sql: """
                    SELECT recipes.id
                    FROM recipes
                    LEFT JOIN cook_sessions
                      ON cook_sessions.recipe_id = recipes.id
                     AND cook_sessions.status = 'completed'
                    GROUP BY recipes.id
                    ORDER BY recipes.is_favorite DESC,
                             MAX(cook_sessions.ended_at) DESC,
                             recipes.title COLLATE NOCASE,
                             recipes.id
                    """
            )
            return try identifiers.map { identifier in
                guard let id = UUID(uuidString: identifier),
                      let recipe = try fetchRecipe(id: id, from: db)
                else {
                    throw RecipeRepositoryError.corruptData("Recipe ID '\(identifier)' is invalid.")
                }
                return recipe
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = selectedTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        return recipes.filter { recipe in
            let matchesTitle = query.isEmpty || recipe.title.localizedCaseInsensitiveContains(query)
            let matchesTag = tag?.isEmpty != false || recipe.tags.contains {
                $0.caseInsensitiveCompare(tag ?? "") == .orderedSame
            }
            return matchesTitle && matchesTag
        }
    }

    func beginCook(for recipeID: UUID, at date: Date = Date()) throws -> CookSession {
        try database.write { db in
            if let active = try fetchActiveCookSession(for: recipeID, from: db) {
                return active
            }
            let id = UUID()
            try db.execute(
                sql: """
                    INSERT INTO cook_sessions
                        (id, recipe_id, started_at, status, current_step)
                    VALUES (?, ?, ?, 'active', 0)
                    """,
                arguments: [id.uuidString, recipeID.uuidString, date]
            )
            return CookSession(
                id: id,
                recipeID: recipeID,
                startedAt: date,
                endedAt: nil,
                status: .active,
                currentStepIndex: 0
            )
        }
    }

    func fetchCookSessions(for recipeID: UUID) throws -> [CookSession] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, recipe_id, started_at, ended_at, status, current_step
                    FROM cook_sessions
                    WHERE recipe_id = ?
                    ORDER BY started_at, id
                    """,
                arguments: [recipeID.uuidString]
            ).map(decodeCookSession)
        }
    }

    /// Durable fetch of one cook session by id (any status). Used by the
    /// console mirror on (re)adopt, so the wall reflects the persisted row
    /// rather than in-memory guesses after a fold/unfold view replacement.
    func fetchCookSession(id: UUID) throws -> CookSession? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, recipe_id, started_at, ended_at, status, current_step
                    FROM cook_sessions
                    WHERE id = ?
                    """,
                arguments: [id.uuidString]
            ) else { return nil }
            return try decodeCookSession(row)
        }
    }

    func updateCookPosition(sessionID: UUID, to stepIndex: Int) throws {
        guard stepIndex >= 0 else { throw CookSessionError.invalidStep }
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_sessions
                    SET current_step = ?
                    WHERE id = ? AND status = 'active'
                      AND ? < (
                        SELECT COUNT(*) FROM recipe_steps
                        WHERE recipe_id = cook_sessions.recipe_id
                      )
                    """,
                arguments: [stepIndex, sessionID.uuidString, stepIndex]
            )
            guard db.changesCount == 1 else { throw CookSessionError.invalidStep }
        }
    }

    func endCook(
        sessionID: UUID,
        as status: CookSessionStatus,
        at date: Date = Date()
    ) throws {
        guard status != .active else { throw CookSessionError.notActive }
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_sessions
                    SET status = ?, ended_at = ?
                    WHERE id = ? AND status = 'active'
                    """,
                arguments: [status.rawValue, date, sessionID.uuidString]
            )
            guard db.changesCount == 1 else { throw CookSessionError.notActive }
        }
    }

    func update(_ recipe: Recipe) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE recipes
                    SET title = ?, servings = ?, is_favorite = ?
                    WHERE id = ?
                    """,
                arguments: [
                    recipe.title,
                    recipe.servings,
                    recipe.isFavorite,
                    recipe.id.uuidString,
                ]
            )
            guard db.changesCount == 1 else {
                throw RecipeRepositoryError.notFound(recipe.id)
            }
            try deleteChildren(of: recipe.id, from: db)
            try insertChildren(of: recipe, into: db)
            try db.execute(
                sql: """
                    UPDATE cook_sessions
                    SET current_step = ?
                    WHERE recipe_id = ? AND status = 'active' AND current_step >= ?
                    """,
                arguments: [recipe.steps.count - 1, recipe.id.uuidString, recipe.steps.count]
            )
        }
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM recipes WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount == 1
        }
    }

    private func insert(_ recipe: Recipe, into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
            arguments: [
                recipe.id.uuidString,
                recipe.title,
                recipe.servings,
                recipe.isFavorite,
            ]
        )
        try insertChildren(of: recipe, into: db)
    }

    private func insertChildren(of recipe: Recipe, into db: Database) throws {
        for (position, ingredient) in recipe.ingredients.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO ingredients
                        (id, recipe_id, position, name, amount, unit)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    ingredient.id.uuidString,
                    recipe.id.uuidString,
                    position,
                    ingredient.name,
                    ingredient.amount,
                    ingredient.unit.rawValue,
                ]
            )
        }
        for (position, step) in recipe.steps.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO recipe_steps
                        (id, recipe_id, position, instruction, timer_duration)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    step.id.uuidString,
                    recipe.id.uuidString,
                    position,
                    step.instruction,
                    step.timerDuration,
                ]
            )
        }
        for (position, tag) in recipe.tags.enumerated() {
            try db.execute(
                sql: "INSERT INTO recipe_tags (recipe_id, position, name) VALUES (?, ?, ?)",
                arguments: [recipe.id.uuidString, position, tag]
            )
        }
    }

    private func deleteChildren(of id: UUID, from db: Database) throws {
        let arguments: StatementArguments = [id.uuidString]
        try db.execute(sql: "DELETE FROM ingredients WHERE recipe_id = ?", arguments: arguments)
        try db.execute(sql: "DELETE FROM recipe_steps WHERE recipe_id = ?", arguments: arguments)
        try db.execute(sql: "DELETE FROM recipe_tags WHERE recipe_id = ?", arguments: arguments)
    }

    private func fetchRecipe(id: UUID, from db: Database) throws -> Recipe? {
        guard let recipeRow = try Row.fetchOne(
            db,
            sql: "SELECT id, title, servings, is_favorite FROM recipes WHERE id = ?",
            arguments: [id.uuidString]
        ) else { return nil }

        let ingredientRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, amount, unit
                FROM ingredients WHERE recipe_id = ? ORDER BY position
                """,
            arguments: [id.uuidString]
        )
        let stepRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, instruction, timer_duration
                FROM recipe_steps WHERE recipe_id = ? ORDER BY position
                """,
            arguments: [id.uuidString]
        )
        let tags = try String.fetchAll(
            db,
            sql: "SELECT name FROM recipe_tags WHERE recipe_id = ? ORDER BY position",
            arguments: [id.uuidString]
        )

        do {
            let ingredients = try ingredientRows.map { row -> Ingredient in
                let idString: String = row["id"]
                let unitString: String = row["unit"]
                guard let ingredientID = UUID(uuidString: idString),
                      let unit = IngredientUnit(rawValue: unitString)
                else {
                    throw RecipeRepositoryError.corruptData("Invalid ingredient ID or unit.")
                }
                return try Ingredient(
                    id: ingredientID,
                    name: row["name"],
                    amount: row["amount"],
                    unit: unit
                )
            }
            let steps = try stepRows.map { row -> RecipeStep in
                let idString: String = row["id"]
                guard let stepID = UUID(uuidString: idString) else {
                    throw RecipeRepositoryError.corruptData("Invalid step ID.")
                }
                return try RecipeStep(
                    id: stepID,
                    instruction: row["instruction"],
                    timerDuration: row["timer_duration"]
                )
            }
            let storedID: String = recipeRow["id"]
            guard UUID(uuidString: storedID) == id else {
                throw RecipeRepositoryError.corruptData("Recipe ID did not round-trip.")
            }
            return try Recipe(
                id: id,
                title: recipeRow["title"],
                servings: recipeRow["servings"],
                ingredients: ingredients,
                steps: steps,
                tags: tags,
                isFavorite: recipeRow["is_favorite"]
            )
        } catch let error as RecipeRepositoryError {
            throw error
        } catch {
            throw RecipeRepositoryError.corruptData(error.localizedDescription)
        }
    }

    private func fetchActiveCookSession(
        for recipeID: UUID,
        from db: Database
    ) throws -> CookSession? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, recipe_id, started_at, ended_at, status, current_step
                FROM cook_sessions
                WHERE recipe_id = ? AND status = 'active'
                ORDER BY started_at DESC, id DESC
                LIMIT 1
                """,
            arguments: [recipeID.uuidString]
        ) else { return nil }
        return try decodeCookSession(row)
    }

    private func decodeCookSession(_ row: Row) throws -> CookSession {
        let idString: String = row["id"]
        let recipeIDString: String = row["recipe_id"]
        let statusString: String = row["status"]
        guard let id = UUID(uuidString: idString),
              let recipeID = UUID(uuidString: recipeIDString),
              let status = CookSessionStatus(rawValue: statusString)
        else {
            throw RecipeRepositoryError.corruptData("Invalid cook session identity or status.")
        }
        return CookSession(
            id: id,
            recipeID: recipeID,
            startedAt: row["started_at"],
            endedAt: row["ended_at"],
            status: status,
            currentStepIndex: row["current_step"]
        )
    }
}
