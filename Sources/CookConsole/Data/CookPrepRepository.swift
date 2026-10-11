import Foundation
import GRDB

extension RecipeRepository {
    func cookPrep(sessionID: UUID) throws -> CookPrep? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT data FROM cook_prep WHERE session_id = ?", arguments: [sessionID.uuidString]) else { return nil }
            let value = try JSONDecoder().decode(CookPrep.self, from: data)
            return try CookPrep(servings: value.servings, checkedIngredientIDs: value.checkedIngredientIDs,
                                equipment: value.equipment, swapped: value.swapped)
        }
    }

    func saveCookPrep(_ value: CookPrep, sessionID: UUID) throws {
        let validated = try CookPrep(servings: value.servings, checkedIngredientIDs: value.checkedIngredientIDs,
                                     equipment: value.equipment, swapped: value.swapped)
        let data = try JSONEncoder().encode(validated)
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT status = 'active' FROM cook_sessions WHERE id = ?", arguments: [sessionID.uuidString]) == true else {
                throw CookSessionError.notActive
            }
            try db.execute(sql: "INSERT INTO cook_prep(session_id, data) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET data = excluded.data",
                           arguments: [sessionID.uuidString, data])
        }
    }
}
