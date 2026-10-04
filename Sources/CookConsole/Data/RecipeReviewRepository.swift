import Foundation
import GRDB

enum RecipeReviewRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case let .invalidData(reason):
            return "Stored recipe-review data is invalid: \(reason)"
        }
    }
}

/// Persistence for issue #21's review + kitchen-test ledger. Writes go
/// through the domain types, so blank notes/justifications and
/// non-positive revisions can never be persisted.
final class RecipeReviewRepository: @unchecked Sendable {
    private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    func save(_ record: RecipeReviewRecord) throws {
        let exceptionsJSON = try Self.encodeExceptions(record.editorialExceptions)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recipe_reviews
                        (recipe_id, review_status, source_provenance,
                         content_revision, editorial_exceptions, test_priority)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(recipe_id) DO UPDATE SET
                        review_status = excluded.review_status,
                        source_provenance = excluded.source_provenance,
                        content_revision = excluded.content_revision,
                        editorial_exceptions = excluded.editorial_exceptions,
                        test_priority = excluded.test_priority
                    """,
                arguments: [
                    record.recipeID.uuidString,
                    record.reviewStatus.rawValue,
                    record.sourceProvenance,
                    record.contentRevision,
                    exceptionsJSON,
                    record.testPriority,
                ]
            )
            // Observations are append-only; re-saving a record never
            // deletes physical-test history.
            try insertMissingObservations(record.observations, recipeID: record.recipeID, db: db)
        }
    }

    /// Record one physical kitchen test. This is the ONLY way ledger
    /// evidence enters the database.
    @discardableResult
    func addObservation(_ observation: KitchenTestObservation, recipeID: UUID) throws -> KitchenTestObservation {
        try database.write { db in
            let exists: Bool = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM recipe_reviews WHERE recipe_id = ?
                    )
                    """,
                arguments: [recipeID.uuidString]
            ) ?? false
            if !exists {
                // A test without a review row still needs a home; create a
                // minimal desk-review row so provenance is never implicit.
                try db.execute(
                    sql: """
                        INSERT INTO recipe_reviews
                            (recipe_id, review_status, source_provenance,
                             content_revision, editorial_exceptions, test_priority)
                        VALUES (?, 'unreviewed', NULL, 1, '[]', NULL)
                        """,
                    arguments: [recipeID.uuidString]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO kitchen_test_observations
                        (id, recipe_id, tested_at, result, notes, tester)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    observation.id.uuidString,
                    recipeID.uuidString,
                    observation.testedAt,
                    observation.result.rawValue,
                    observation.notes,
                    observation.tester,
                ]
            )
            // Physical evidence clears any stale queue slot.
            try db.execute(
                sql: "UPDATE recipe_reviews SET test_priority = NULL WHERE recipe_id = ?",
                arguments: [recipeID.uuidString]
            )
            return observation
        }
    }

    /// Adoption of curated pack metadata, restricted to recipes that
    /// actually exist in this database. Starter-pack UUIDs referencing
    /// un-seeded demo content are skipped — the review board reads those
    /// entries live from the pack instead; the database stays the home of
    /// durable per-user data (physical observations, and from #25 onward
    /// local-edit revision tracking).
    func adoptPackMetadata(_ records: [RecipeReviewRecord]) throws {
        try database.write { db in
            for record in records {
                let known: Bool = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM recipes WHERE id = ?)",
                    arguments: [record.recipeID.uuidString]
                ) ?? false
                guard known else { continue }
                let json = try Self.encodeExceptions(record.editorialExceptions)
                try db.execute(
                    sql: """
                        INSERT INTO recipe_reviews
                            (recipe_id, review_status, source_provenance,
                             content_revision, editorial_exceptions, test_priority)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(recipe_id) DO UPDATE SET
                            review_status = excluded.review_status,
                            source_provenance = excluded.source_provenance,
                            content_revision = excluded.content_revision,
                            editorial_exceptions = excluded.editorial_exceptions,
                            test_priority = COALESCE(recipe_reviews.test_priority, excluded.test_priority)
                        """,
                    arguments: [
                        record.recipeID.uuidString,
                        record.reviewStatus.rawValue,
                        record.sourceProvenance,
                        record.contentRevision,
                        json,
                        record.testPriority,
                    ]
                )
            }
        }
    }

    func fetch(recipeID: UUID) throws -> RecipeReviewRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT review_status, source_provenance, content_revision,
                           editorial_exceptions, test_priority
                    FROM recipe_reviews
                    WHERE recipe_id = ?
                    """,
                arguments: [recipeID.uuidString]
            ) else { return nil }
            return try record(from: row, recipeID: recipeID, db: db)
        }
    }

    func fetchAll() throws -> [RecipeReviewRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT recipe_id, review_status, source_provenance,
                           content_revision, editorial_exceptions, test_priority
                    FROM recipe_reviews
                    ORDER BY recipe_id
                    """
            )
            return try rows.map { row in
                let idString: String = row["recipe_id"]
                guard let id = UUID(uuidString: idString) else {
                    throw RecipeReviewRepositoryError.invalidData("Invalid recipe UUID \(idString)")
                }
                return try record(from: row, recipeID: id, db: db)
            }
        }
    }

    // MARK: - Helpers

    private func record(from row: Row, recipeID: UUID, db: Database) throws -> RecipeReviewRecord {
        let rawStatus: String = row["review_status"]
        guard let status = RecipeReviewStatus(rawValue: rawStatus) else {
            throw RecipeReviewRepositoryError.invalidData("Invalid review status \(rawStatus)")
        }
        let provenance: String? = row["source_provenance"]
        let revision: Int = row["content_revision"]
        let exceptionsJSON: String = row["editorial_exceptions"]
        let priorityRaw: Int? = row["test_priority"]
        let exceptions = try Self.decodeExceptions(exceptionsJSON)
        let observations = try Self.fetchObservations(recipeID: recipeID, db: db)
        do {
            return try RecipeReviewRecord(
                recipeID: recipeID,
                reviewStatus: status,
                sourceProvenance: provenance,
                contentRevision: revision,
                editorialExceptions: exceptions,
                testPriority: priorityRaw,
                observations: observations
            )
        } catch {
            throw RecipeReviewRepositoryError.invalidData("Unreconstructable record: \(error)")
        }
    }

    private static func fetchObservations(recipeID: UUID, db: Database) throws -> [KitchenTestObservation] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, tested_at, result, notes, tester
                FROM kitchen_test_observations
                WHERE recipe_id = ?
                ORDER BY tested_at DESC, id
                """,
            arguments: [recipeID.uuidString]
        )
        return try rows.map { row in
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw RecipeReviewRepositoryError.invalidData("Invalid observation UUID \(idString)")
            }
            let rawResult: String = row["result"]
            guard let result = KitchenTestResult(rawValue: rawResult) else {
                throw RecipeReviewRepositoryError.invalidData("Invalid result \(rawResult)")
            }
            do {
                return try KitchenTestObservation(
                    id: id,
                    testedAt: row["tested_at"],
                    result: result,
                    notes: row["notes"],
                    tester: row["tester"]
                )
            } catch {
                throw RecipeReviewRepositoryError.invalidData("Unreconstructable observation: \(error)")
            }
        }
    }

    private func insertMissingObservations(
        _ observations: [KitchenTestObservation],
        recipeID: UUID,
        db: Database
    ) throws {
        for observation in observations {
            let seen: Bool = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM kitchen_test_observations WHERE id = ?)",
                arguments: [observation.id.uuidString]
            ) ?? false
            guard !seen else { continue }
            try db.execute(
                sql: """
                    INSERT INTO kitchen_test_observations
                        (id, recipe_id, tested_at, result, notes, tester)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    observation.id.uuidString,
                    recipeID.uuidString,
                    observation.testedAt,
                    observation.result.rawValue,
                    observation.notes,
                    observation.tester,
                ]
            )
        }
    }

    struct StoredException: Codable {
        let phrase: String
        let justification: String
    }

    private static func encodeExceptions(_ exceptions: [EditorialException]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stored = exceptions.map { StoredException(phrase: $0.phrase, justification: $0.justification) }
        let data = try encoder.encode(stored)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RecipeReviewRepositoryError.invalidData("Exception JSON is not UTF-8")
        }
        return json
    }

    private static func decodeExceptions(_ json: String) throws -> [EditorialException] {
        let decoder = JSONDecoder()
        do {
            let stored = try decoder.decode([StoredException].self, from: Data(json.utf8))
            return try stored.map {
                try EditorialException(phrase: $0.phrase, justification: $0.justification)
            }
        } catch is DecodingError {
            throw RecipeReviewRepositoryError.invalidData("Editorial exception JSON is corrupt")
        }
        // Domain validation errors (blank phrase/justification) propagate
        // unchanged — they ARE the corrupt-data signal we want surfaced.
    }
}
