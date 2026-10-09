import Foundation
import GRDB

struct PersonalRecipeNotes: Codable, Equatable, Sendable {
    let recipeID: UUID
    let notes: String
    let rating: Int?

    init(recipeID: UUID, notes: String = "", rating: Int? = nil) throws {
        guard rating.map({ (1...5).contains($0) }) ?? true else {
            throw DataTransferError.invalidItem(path: "personal notes \(recipeID)", reason: "Rating must be 1–5 or unrated.")
        }
        guard notes.count <= 20_000 else {
            throw DataTransferError.invalidItem(path: "personal notes \(recipeID)", reason: "Notes must be at most 20,000 characters.")
        }
        self.recipeID = recipeID
        self.notes = notes
        self.rating = rating
    }
}

extension RecipeRepository {
    func personalNotes(for recipeID: UUID) throws -> PersonalRecipeNotes {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT notes, rating FROM personal_recipe_notes WHERE recipe_id = ?", arguments: [recipeID.uuidString]) else {
                return try PersonalRecipeNotes(recipeID: recipeID)
            }
            return try PersonalRecipeNotes(recipeID: recipeID, notes: row["notes"], rating: row["rating"])
        }
    }

    func savePersonalNotes(_ value: PersonalRecipeNotes) throws {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM recipes WHERE id = ? AND deleted_at IS NULL)", arguments: [value.recipeID.uuidString]) == true else {
                throw RecipeRepositoryError.notFound(value.recipeID)
            }
            try Self.writePersonalNotes(value, in: db)
        }
    }

    static func writePersonalNotes(_ value: PersonalRecipeNotes, in db: Database) throws {
        // Codable can construct values without invoking the validated initializer.
        _ = try PersonalRecipeNotes(recipeID: value.recipeID, notes: value.notes, rating: value.rating)
        try db.execute(sql: """
            INSERT INTO personal_recipe_notes (recipe_id, notes, rating) VALUES (?, ?, ?)
            ON CONFLICT(recipe_id) DO UPDATE SET notes = excluded.notes, rating = excluded.rating
            """, arguments: [value.recipeID.uuidString, value.notes, value.rating])
    }

    static func allPersonalNotes(in db: Database) throws -> [PersonalRecipeNotes] {
        try Row.fetchAll(db, sql: "SELECT recipe_id, notes, rating FROM personal_recipe_notes ORDER BY recipe_id").map { row in
            let identifier: String = row["recipe_id"]
            guard let id = UUID(uuidString: identifier) else { throw RecipeRepositoryError.corruptData("Invalid personal-note recipe ID.") }
            return try PersonalRecipeNotes(recipeID: id, notes: row["notes"], rating: row["rating"])
        }
    }
}

struct RecipeCookingSummary: Equatable, Sendable {
    let completedSessions: [CookSession]
    var lastCookedAt: Date? { completedSessions.first?.endedAt }

    init(sessions: [CookSession]) {
        completedSessions = sessions.filter { $0.status == .completed && $0.endedAt != nil }.sorted {
            if $0.endedAt != $1.endedAt { return $0.endedAt! > $1.endedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
