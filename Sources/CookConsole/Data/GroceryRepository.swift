import Foundation
import GRDB

/// Durable store for the combined grocery list (issue #20): recipe
/// selections (recipe + chosen servings + per-ingredient-key check flags)
/// and manual shopping lines. Everything persists in the app's local GRDB
/// file — no account, no cloud (the CI zero-network gate keeps it that way).
///
/// Check state intentionally lives in `grocery_selection_checks`, keyed on
/// (selection, ingredient name key): a merged shopping line (e.g. Olive oil
/// from two recipes) is checked iff EVERY contributing selection has its row
/// for that key checked. A per-selection flag would cascade one merged tap
/// across unrelated ingredients of the other recipe; per-key rows cannot.
///
/// Recipe edits intentionally do NOT touch selections: servings and
/// ingredient changes re-derive the aggregation on every load, and the
/// checked state is recomputed by `GroceryAggregationEngine`, so edits never
/// silently destroy check state beyond what the selections imply. Deleting a
/// recipe removes its selections (and their check rows via the schema's
/// CASCADE rules) predictably.
final class GroceryRepository: @unchecked Sendable {
    enum GroceryRepositoryError: Error, Equatable, LocalizedError, Sendable {
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case let .invalidData(reason):
                return "Stored grocery data is invalid: \(reason)"
            }
        }
    }

    private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    // MARK: - Selections

    func fetchSelections() throws -> [GrocerySelection] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, recipe_id, servings, position
                    FROM grocery_selections
                    ORDER BY position, id
                    """
            )
            return try rows.map { row in
                guard let base = try decodeSelection(row) else {
                    throw GroceryRepositoryError.invalidData("Unreadable grocery selection row.")
                }
                let checkedKeys = try Set(String.fetchAll(
                    db,
                    sql: "SELECT ingredient_key FROM grocery_selection_checks WHERE selection_id = ? AND is_checked = 1",
                    arguments: [base.id.uuidString]
                ))
                return try GrocerySelection(
                    id: base.id,
                    recipeID: base.recipeID,
                    servings: base.servings,
                    checkedKeys: checkedKeys,
                    position: base.position
                )
            }
        }
    }

    /// Number of next-position slots so new selections append in tap order.
    /// A recipe may occupy the list only once: re-adding an already-selected
    /// recipe returns the existing selection instead of double-counting its
    /// ingredients.
    @discardableResult
    func addSelection(recipeID: UUID, servings: Double) throws -> GrocerySelection {
        let candidate = try GrocerySelection(recipeID: recipeID, servings: servings)
        return try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM recipes WHERE id = ? AND deleted_at IS NULL)", arguments: [recipeID.uuidString]) == true else {
                throw GroceryRepositoryError.invalidData("Only a recipe in the library can be added to groceries.")
            }
            if let existingID: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM grocery_selections WHERE recipe_id = ? LIMIT 1",
                arguments: [recipeID.uuidString]
            ), let existing = try selectionByID(db, id: existingID) {
                return existing
            }
            let next: Int = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM grocery_selections"
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO grocery_selections (id, recipe_id, servings, position)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    candidate.id.uuidString,
                    candidate.recipeID.uuidString,
                    candidate.servings,
                    next,
                ]
            )
            return candidate.withPosition(next)
        }
    }

    func updateServings(selectionID: UUID, servings: Double) throws {
        guard servings.isFinite, servings > 0, servings < 1e9 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Selection servings")
        }
        try database.write { db in
            try db.execute(
                sql: "UPDATE grocery_selections SET servings = ? WHERE id = ?",
                arguments: [servings, selectionID.uuidString]
            )
        }
    }

    /// Set the bought flag for ONE ingredient key of ONE selection — the
    /// primitive behind per-line checks. The engine decides which
    /// selections a merged line fans out to; this method stays dumb.
    func setChecked(selectionID: UUID, ingredientKey: String, isChecked: Bool) throws {
        let key = ingredientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 200 else {
            throw GroceryRepositoryError.invalidData("Ingredient key must be non-blank and shorter than 200 bytes.")
        }
        try database.write { db in
            guard try selectionExists(db, id: selectionID) else { return }
            if isChecked {
                try db.execute(
                    sql: """
                        INSERT INTO grocery_selection_checks (selection_id, ingredient_key, is_checked)
                        VALUES (?, ?, 1)
                        ON CONFLICT(selection_id, ingredient_key) DO UPDATE SET is_checked = 1
                        """,
                    arguments: [selectionID.uuidString, key]
                )
            } else {
                // Unchecking deletes the row: absence == unchecked, so the
                // table only ever holds bought (key, selection) pairs.
                try db.execute(
                    sql: "DELETE FROM grocery_selection_checks WHERE selection_id = ? AND ingredient_key = ?",
                    arguments: [selectionID.uuidString, key]
                )
            }
        }
    }

    /// Fan-out variant used when the user checks/unchecks a merged recipe
    /// line: every contributing selection takes the flag for that key
    /// atomically.
    func setChecked(selectionIDs: [UUID], ingredientKey: String, isChecked: Bool) throws {
        let key = ingredientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 200 else {
            throw GroceryRepositoryError.invalidData("Ingredient key must be non-blank and shorter than 200 bytes.")
        }
        guard !selectionIDs.isEmpty else { return }
        try database.write { db in
            for id in selectionIDs {
                guard try selectionExists(db, id: id) else { continue }
                if isChecked {
                    try db.execute(
                        sql: """
                            INSERT INTO grocery_selection_checks (selection_id, ingredient_key, is_checked)
                            VALUES (?, ?, 1)
                            ON CONFLICT(selection_id, ingredient_key) DO UPDATE SET is_checked = 1
                            """,
                        arguments: [id.uuidString, key]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM grocery_selection_checks WHERE selection_id = ? AND ingredient_key = ?",
                        arguments: [id.uuidString, key]
                    )
                }
            }
        }
    }

    @discardableResult
    func removeSelection(id: UUID) throws -> Bool {
        try database.write { db in
            // grocery_selection_checks cascades from grocery_selections.
            try db.execute(
                sql: "DELETE FROM grocery_selections WHERE id = ?",
                arguments: [id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    // MARK: - Manual items

    func fetchManualItems() throws -> [GroceryManualItem] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, is_checked, position
                    FROM grocery_manual_items
                    ORDER BY position, id
                    """
            ).compactMap { row -> GroceryManualItem? in
                let idString: String = row["id"]
                guard let id = UUID(uuidString: idString) else { return nil }
                let name: String = row["name"]
                let isChecked: Bool = row["is_checked"]
                let position: Int = row["position"]
                return try? GroceryManualItem(
                    id: id,
                    name: name,
                    isChecked: isChecked,
                    position: position
                )
            }
        }
    }

    @discardableResult
    func addManualItem(name: String) throws -> GroceryManualItem {
        let candidate = try GroceryManualItem(name: name)
        return try database.write { db in
            let next: Int = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM grocery_manual_items"
            ) ?? 0
            let positioned = try GroceryManualItem(
                id: candidate.id,
                name: candidate.name,
                isChecked: candidate.isChecked,
                position: next
            )
            try db.execute(
                sql: """
                    INSERT INTO grocery_manual_items (id, name, is_checked, position)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    positioned.id.uuidString,
                    positioned.name,
                    positioned.isChecked,
                    positioned.position,
                ]
            )
            return positioned
        }
    }

    func setManualItemChecked(id: UUID, isChecked: Bool) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE grocery_manual_items SET is_checked = ? WHERE id = ?",
                arguments: [isChecked, id.uuidString]
            )
        }
    }

    @discardableResult
    func removeManualItem(id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM grocery_manual_items WHERE id = ?",
                arguments: [id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// "Done shopping": every bought flag clears so the next trip starts
    /// clean while the selections (and their serving choices) survive.
    func uncheckAllSelections() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM grocery_selection_checks")
        }
    }

    func uncheckAllManualItems() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE grocery_manual_items SET is_checked = 0")
        }
    }

    /// "Done shopping" for manual lines: checked items were bought, so they
    /// are removed; unchecked manual items stay. Recipe-derived lines can
    /// never be "deleted" — they re-derive from the selections.
    func removeCheckedManualItems() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM grocery_manual_items WHERE is_checked = 1")
        }
    }

    // MARK: - Row helpers

    private func selectionExists(_ db: Database, id: UUID) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM grocery_selections WHERE id = ?)",
            arguments: [id.uuidString]
        ) ?? false
    }

    private func selectionByID(_ db: Database, id: String) throws -> GrocerySelection? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, recipe_id, servings, position FROM grocery_selections WHERE id = ?",
            arguments: [id]
        ), let base = try decodeSelection(row) else { return nil }
        let checkedKeys = try Set(String.fetchAll(
            db,
            sql: "SELECT ingredient_key FROM grocery_selection_checks WHERE selection_id = ? AND is_checked = 1",
            arguments: [id]
        ))
        return try GrocerySelection(
            id: base.id,
            recipeID: base.recipeID,
            servings: base.servings,
            checkedKeys: checkedKeys,
            position: base.position
        )
    }

    private func decodeSelection(_ row: Row) throws -> GrocerySelection? {
        let idString: String = row["id"]
        let recipeIDString: String = row["recipe_id"]
        guard let id = UUID(uuidString: idString),
              let recipeID = UUID(uuidString: recipeIDString)
        else { return nil }
        let servings: Double = row["servings"]
        let position: Int = row["position"]
        guard servings.isFinite, servings > 0 else { return nil }
        return try? GrocerySelection(
            id: id,
            recipeID: recipeID,
            servings: servings,
            position: position
        )
    }
}
