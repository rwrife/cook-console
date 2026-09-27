import Foundation
import GRDB

enum PantryRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case let .invalidData(reason):
            return "Stored pantry data is invalid: \(reason)"
        }
    }
}

final class PantryRepository: @unchecked Sendable {
    private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    @discardableResult
    func add(name: String, kind: PantryItemKind) throws -> PantryItem {
        let candidate = try PantryItem(name: name, kind: kind)
        return try database.write { db in
            if let existingRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, kind, created_at
                    FROM pantry_items
                    WHERE kind = ? AND lower(name) = lower(?)
                    LIMIT 1
                    """,
                arguments: [kind.rawValue, candidate.name]
            ) {
                let idString: String = existingRow["id"]
                guard let id = UUID(uuidString: idString) else {
                    throw PantryRepositoryError.invalidData("Invalid UUID \(idString)")
                }
                let rawKind: String = existingRow["kind"]
                guard let existingKind = PantryItemKind(rawValue: rawKind) else {
                    throw PantryRepositoryError.invalidData("Invalid kind \(rawKind)")
                }
                return try PantryItem(
                    id: id,
                    name: existingRow["name"],
                    kind: existingKind,
                    createdAt: existingRow["created_at"]
                )
            }

            try db.execute(
                sql: "INSERT INTO pantry_items (id, name, kind, created_at) VALUES (?, ?, ?, ?)",
                arguments: [
                    candidate.id.uuidString,
                    candidate.name,
                    candidate.kind.rawValue,
                    candidate.createdAt,
                ]
            )
            return candidate
        }
    }

    func fetch(kind: PantryItemKind) throws -> [PantryItem] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, kind, created_at
                    FROM pantry_items
                    WHERE kind = ?
                    ORDER BY name COLLATE NOCASE, id
                    """,
                arguments: [kind.rawValue]
            )
            return try rows.map { row in
                let idString: String = row["id"]
                guard let id = UUID(uuidString: idString) else {
                    throw PantryRepositoryError.invalidData("Invalid UUID \(idString)")
                }
                let rawKind: String = row["kind"]
                guard let itemKind = PantryItemKind(rawValue: rawKind) else {
                    throw PantryRepositoryError.invalidData("Invalid kind \(rawKind)")
                }
                return try PantryItem(
                    id: id,
                    name: row["name"],
                    kind: itemKind,
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func fetchAll() throws -> [PantryItem] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, name, kind, created_at FROM pantry_items ORDER BY name COLLATE NOCASE, id"
            )
            return try rows.map { row in
                let idString: String = row["id"]
                guard let id = UUID(uuidString: idString) else {
                    throw PantryRepositoryError.invalidData("Invalid UUID \(idString)")
                }
                let rawKind: String = row["kind"]
                guard let itemKind = PantryItemKind(rawValue: rawKind) else {
                    throw PantryRepositoryError.invalidData("Invalid kind \(rawKind)")
                }
                return try PantryItem(
                    id: id,
                    name: row["name"],
                    kind: itemKind,
                    createdAt: row["created_at"]
                )
            }
        }
    }

    @discardableResult
    func remove(id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM pantry_items WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    func suggestions(for recipes: [Recipe]) throws -> [RecipePantrySuggestion] {
        let onHand = try fetch(kind: .onHand).map(\.name)
        let staples = try fetch(kind: .staple).map(\.name)
        return PantrySuggestionEngine.rank(
            recipes: recipes,
            pantryNames: onHand,
            stapleNames: staples
        )
    }

    /// Seeds visible, editable defaults once. Removing a default later stays
    /// removed because the marker is durable; relaunch never re-inserts it.
    func seedDefaultStaplesIfNeeded() throws {
        try database.write { db in
            let marker: String? = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_metadata WHERE key = 'default_staples_seeded'"
            )
            guard marker == nil else { return }
            for name in PantrySuggestionEngine.defaultStaples {
                try db.execute(
                    sql: "INSERT INTO pantry_items (id, name, kind, created_at) VALUES (?, ?, 'staple', ?)",
                    arguments: [UUID().uuidString, name, Date()]
                )
            }
            try db.execute(
                sql: "INSERT INTO app_metadata (key, value) VALUES ('default_staples_seeded', '1')"
            )
        }
    }
}
