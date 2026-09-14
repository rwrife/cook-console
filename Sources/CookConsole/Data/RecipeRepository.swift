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
    private let database: DatabaseQueue

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
}
