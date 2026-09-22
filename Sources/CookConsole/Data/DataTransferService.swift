import Foundation
import GRDB

/// Errors raised while validating an import document, with the path of the
/// offending item so the UI can report per-item failures.
enum DataTransferError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    case invalidItem(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "This backup uses schema version \(version); this build understands version 1."
        case let .malformed(reason):
            return "The backup file is not readable: \(reason)"
        case let .invalidItem(path, reason):
            return "\(path): \(reason)"
        }
    }
}

/// Versioned JSON backup document: recipes + cook sessions + timer logs.
///
/// The schema is explicit and versioned (acceptance criteria for #6): new
/// fields must be optional and additive, and `schemaVersion` is the only
/// migration key. `appVersion` is informational provenance, never trusted.
struct BackupDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Header: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
    }

    struct StoredIngredient: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var amount: Double
        var unit: String
    }

    struct StoredStep: Codable, Equatable, Sendable {
        var id: UUID
        var instruction: String
        var timerDuration: Double?
    }

    struct StoredRecipe: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var servings: Double
        var isFavorite: Bool
        var tags: [String]
        var ingredients: [StoredIngredient]
        var steps: [StoredStep]
    }

    struct StoredSession: Codable, Equatable, Sendable {
        var id: UUID
        var recipeID: UUID
        var startedAt: Date
        var endedAt: Date?
        var status: String
        var currentStepIndex: Int
    }

    struct StoredTimer: Codable, Equatable, Sendable {
        var id: UUID
        var recipeID: UUID
        var stepID: UUID
        var cookSessionID: UUID
        var stepName: String
        var originalDuration: Double
        var status: String
        var startedAt: Date
        var deadline: Date?
        var remainingWhenPaused: Double?
        var completedAt: Date?
    }

    struct StoredTimerEvent: Codable, Equatable, Sendable {
        var id: UUID
        var timerID: UUID
        var kind: String
        var occurredAt: Date
        var seconds: Double?
    }

    var header: Header
    var recipes: [StoredRecipe]
    var sessions: [StoredSession]
    var timers: [StoredTimer]
    var timerEvents: [StoredTimerEvent]
}

/// Summary of one applied import, shaped for a user-visible conflict report.
struct JSONImportOutcome: Equatable, Sendable {
    var recipesAdded = 0
    var recipesSkipped = 0
    var recipesReplaced = 0
    var sessionsAdded = 0
    var sessionsSkipped = 0
    var timersAdded = 0
    var timersSkipped = 0

    /// Human-readable conflict summary shown after an import.
    var summaryText: String {
        var parts: [String] = ["\(recipesAdded) recipes added"]
        if recipesSkipped > 0 { parts.append("\(recipesSkipped) unchanged duplicates kept") }
        if recipesReplaced > 0 { parts.append("\(recipesReplaced) recipes replaced") }
        parts.append("\(sessionsAdded) cook sessions added")
        if sessionsSkipped > 0 { parts.append("\(sessionsSkipped) sessions already present") }
        parts.append("\(timersAdded) timer logs added")
        if timersSkipped > 0 { parts.append("\(timersSkipped) timer logs already present") }
        return parts.joined(separator: ", ") + "."
    }
}

/// User-owned data transport (issue #6): JSON backup export/restore and a
/// cook-history CSV report.
///
/// Privacy contract: this file — like the whole app — uses ONLY local file
/// APIs (Foundation + GRDB). Data leaves the app through the system share
/// sheet / Files, never through a network API (the CI zero-network grep
/// gate keeps that true). Imports are all-or-nothing per file inside one
/// transaction, and merge is keyed on stable item IDs — an existing recipe
/// is only replaced when the incoming copy validates cleanly.
final class DataTransferService: @unchecked Sendable {
    private let database: DatabaseQueue
    private let appVersion: String
    private let now: @Sendable () -> Date

    init(
        database: DatabaseQueue,
        appVersion: String = AppInfo.versionStamp,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.appVersion = appVersion
        self.now = now
    }

    /// Fixed ISO-8601 wire format for backup documents and CSV timestamps.
    /// A fresh `DateFormatter` per use keeps the service safely `Sendable`
    /// (DateFormatter is documented as not thread-safe) and works identically
    /// on Darwin and swift-corelibs Foundation — `ISO8601DateFormatter`
    /// cannot be used with `JSONEncoder.dateEncodingStrategy`.
    private static func wireFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }

    // MARK: - Export

    /// Snapshot of the whole library into a `BackupDocument`.
    func exportDocument() throws -> BackupDocument {
        let snapshot = try database.read { db in try Self.readSnapshot(db) }
        return BackupDocument(
            header: BackupDocument.Header(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: now(),
                appVersion: appVersion
            ),
            recipes: snapshot.recipes,
            sessions: snapshot.sessions,
            timers: snapshot.timers,
            timerEvents: snapshot.timerEvents
        )
    }

    /// Writes the versioned JSON backup to `destination` and returns it.
    @discardableResult
    func writeJSONBackup(to destination: URL) throws -> URL {
        let document = try exportDocument()
        let data = try encodedData(for: document)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Cook-history CSV (one row per cook session) written to `destination`.
    @discardableResult
    func writeHistoryCSV(to destination: URL) throws -> URL {
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id, s.recipe_id, r.title, s.status, s.started_at,
                           s.ended_at, s.current_step,
                           (SELECT COUNT(*) FROM recipe_steps st WHERE st.recipe_id = s.recipe_id) AS step_count
                    FROM cook_sessions s
                    JOIN recipes r ON r.id = s.recipe_id
                    ORDER BY s.started_at, s.id
                    """
            ).map { row -> [String] in
                let endedAt: Date? = row["ended_at"]
                let stepCount: Int = row["step_count"]
                let currentStep: Int = row["current_step"]
                return [
                    row["id"],
                    row["recipe_id"],
                    row["title"],
                    row["status"],
                    Self.wireFormatter().string(from: row["started_at"]),
                    endedAt.map(Self.wireFormatter().string(from:)) ?? "",
                    String(currentStep),
                    String(stepCount),
                ]
            }
        }
        let header = [
            "session_id", "recipe_id", "recipe_title", "status",
            "started_at", "ended_at", "current_step", "step_count",
        ]
        let csv = ([header] + rows).map { Self.csvLine($0) }.joined(separator: "\n") + "\n"
        try csv.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// Minimal RFC-4180 quoting: quote only when needed, double embedded
    /// quotes. Keeps recipe titles with commas/newlines faithful.
    static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains("\"") || field.contains(",") || field.contains("\n") || field.contains("\r") {
                "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            } else {
                field
            }
        }.joined(separator: ",")
    }

    // MARK: - Import

    /// Validates a JSON backup WITHOUT touching the database, so malformed
    /// or unsupported files are rejected with zero side effects.
    func validateDocument(at url: URL) throws -> BackupDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DataTransferError.malformed("File could not be read (\(error.localizedDescription)).")
        }
        let document: BackupDocument
        do {
            document = try decodedDocument(from: data)
        } catch let error as DataTransferError {
            throw error
        } catch {
            throw DataTransferError.malformed(error.localizedDescription)
        }
        guard document.header.schemaVersion == BackupDocument.currentSchemaVersion else {
            throw DataTransferError.unsupportedSchemaVersion(document.header.schemaVersion)
        }
        try Self.validateSemantics(of: document)
        return document
    }

    /// Applies a previously validated document inside a single transaction:
    /// a mid-write failure rolls everything back (no partial-file corruption).
    ///
    /// Merge-not-clobber, keyed on stable item IDs:
    /// - recipe ID unknown in the store  -> added (children inserted)
    /// - recipe ID already known         -> the incoming copy re-validates
    ///   through the domain model first (rejecting garbage before any write),
    ///   then replaces the row in place so the backup wins without ever
    ///   deleting a recipe the incoming file could not fully describe.
    /// - session/timer/event IDs already known -> skipped (history logs are
    ///   append-only; an existing row is never rewritten).
    @discardableResult
    func applyValidated(_ document: BackupDocument) throws -> JSONImportOutcome {
        var outcome = JSONImportOutcome()
        try database.write { db in
            let existingRecipeIDs = try Set(String.fetchAll(db, sql: "SELECT id FROM recipes"))
            let existingSessionIDs = try Set(String.fetchAll(db, sql: "SELECT id FROM cook_sessions"))
            let existingTimerIDs = try Set(String.fetchAll(db, sql: "SELECT id FROM cook_timers"))
            let existingEventIDs = try Set(String.fetchAll(db, sql: "SELECT id FROM timer_events"))

            let documentRecipeIDs = Set(document.recipes.map { $0.id.uuidString })
            let documentSessionIDs = Set(document.sessions.map { $0.id.uuidString })
            let documentTimerIDs = Set(document.timers.map { $0.id.uuidString })

            // DB-aware cross-reference existence checks (in addition to the
            // in-document checks from validateSemantics): a referenced row
            // may live in the file OR already in the store. Failing here
            // rolls the whole transaction back, so the file is all-or-nothing.
            for stored in document.sessions where
                !documentRecipeIDs.contains(stored.recipeID.uuidString)
                    && !existingRecipeIDs.contains(stored.recipeID.uuidString)
            {
                throw DataTransferError.invalidItem(
                    path: "session \(stored.id.uuidString)",
                    reason: "references recipe \(stored.recipeID.uuidString), which exists neither in the file nor in the library."
                )
            }
            for stored in document.timers where
                !documentSessionIDs.contains(stored.cookSessionID.uuidString)
                    && !existingSessionIDs.contains(stored.cookSessionID.uuidString)
            {
                throw DataTransferError.invalidItem(
                    path: "timer \(stored.id.uuidString)",
                    reason: "references cook session \(stored.cookSessionID.uuidString), which exists neither in the file nor in the library."
                )
            }
            for stored in document.timerEvents where
                !documentTimerIDs.contains(stored.timerID.uuidString)
                    && !existingTimerIDs.contains(stored.timerID.uuidString)
            {
                throw DataTransferError.invalidItem(
                    path: "timer event \(stored.id.uuidString)",
                    reason: "references timer \(stored.timerID.uuidString), which exists neither in the file nor in the library."
                )
            }

            for stored in document.recipes {
                // Rejects invalid copies via the validated domain model
                // before anything mutates (all-or-nothing per file).
                let recipe = try Self.decodedRecipe(stored)
                let key = stored.id.uuidString
                if existingRecipeIDs.contains(key) {
                    if try Self.storedRecipe(db, id: recipe.id) == recipe {
                        outcome.recipesSkipped += 1
                    } else {
                        try Self.replaceRecipe(db, with: recipe)
                        outcome.recipesReplaced += 1
                    }
                } else {
                    try Self.insertRecipe(db, recipe)
                    outcome.recipesAdded += 1
                }
            }

            // A backup restores history (timers whose sessions ended in the
            // past), and the live-editing `cook_timers_valid_identity_insert`
            // trigger requires the session to be 'active' at insert time.
            // Rather than dropping triggers, the import satisfies them the
            // way the app itself does: every session a restored timer
            // touches is flipped to 'active' for the duration of the insert
            // and restored to its true final status afterwards. Column
            // shape rules (running=deadline, paused=remaining, ended=
            // completed_at) are already honored by the stored columns.
            var sessionFinalStatus: [String: String] = [:]
            func ensureSessionActiveForTimerInsert(_ sessionKey: String) throws {
                guard sessionFinalStatus[sessionKey] == nil else { return }
                let status: String? = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM cook_sessions WHERE id = ?",
                    arguments: [sessionKey]
                )
                guard let status else { return } // FK check catches unknown sessions
                sessionFinalStatus[sessionKey] = status
                if status != CookSessionStatus.active.rawValue {
                    try db.execute(
                        sql: "UPDATE cook_sessions SET status = ? WHERE id = ?",
                        arguments: [CookSessionStatus.active.rawValue, sessionKey]
                    )
                }
            }

            for stored in document.sessions {
                let key = stored.id.uuidString
                guard !existingSessionIDs.contains(key) else {
                    outcome.sessionsSkipped += 1
                    continue
                }
                try db.execute(
                    sql: """
                        INSERT INTO cook_sessions
                            (id, recipe_id, started_at, ended_at, status, current_step)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        key,
                        stored.recipeID.uuidString,
                        stored.startedAt,
                        stored.endedAt,
                        stored.status,
                        stored.currentStepIndex,
                    ]
                )
                outcome.sessionsAdded += 1
            }

            for stored in document.timers {
                let key = stored.id.uuidString
                guard !existingTimerIDs.contains(key) else {
                    outcome.timersSkipped += 1
                    continue
                }
                // DB-aware step existence: when the timer's recipe lives in
                // the store (not the file), validateSemantics could not see
                // its steps. The identity trigger would abort the whole
                // transaction otherwise — report the item instead.
                let stepExists = (try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM recipe_steps
                            WHERE recipe_id = ? AND id = ?
                        )
                        """,
                    arguments: [stored.recipeID.uuidString, stored.stepID.uuidString]
                )) ?? false
                guard stepExists else {
                    throw DataTransferError.invalidItem(
                        path: "timer \(key)",
                        reason: "references step \(stored.stepID.uuidString), which does not exist in the recipe it names."
                    )
                }
                try ensureSessionActiveForTimerInsert(stored.cookSessionID.uuidString)
                try db.execute(
                    sql: """
                        INSERT INTO cook_timers
                            (id, recipe_id, step_id, cook_session_id, step_name,
                             original_duration, status, started_at, deadline,
                             remaining_when_paused, completed_at, schedule_generation)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        key,
                        stored.recipeID.uuidString,
                        stored.stepID.uuidString,
                        stored.cookSessionID.uuidString,
                        stored.stepName,
                        stored.originalDuration,
                        stored.status,
                        stored.startedAt,
                        stored.deadline,
                        stored.remainingWhenPaused,
                        stored.completedAt,
                        1,
                    ]
                )
                outcome.timersAdded += 1
            }

            // Restore the true final status of every session that was
            // temporarily reactivated to satisfy the timer-insert trigger.
            for (sessionKey, finalStatus) in sessionFinalStatus {
                if finalStatus != CookSessionStatus.active.rawValue {
                    try db.execute(
                        sql: "UPDATE cook_sessions SET status = ? WHERE id = ?",
                        arguments: [finalStatus, sessionKey]
                    )
                }
            }

            for stored in document.timerEvents {
                let key = stored.id.uuidString
                guard !existingEventIDs.contains(key) else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO timer_events
                            (id, timer_id, event_kind, occurred_at, seconds)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        key,
                        stored.timerID.uuidString,
                        stored.kind,
                        stored.occurredAt,
                        stored.seconds,
                    ]
                )
            }
        }
        return outcome
    }

    // MARK: - Coding

    func encodedData(for document: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(Self.wireFormatter())
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(document)
    }

    func decodedDocument(from data: Data) throws -> BackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(Self.wireFormatter())
        return try decoder.decode(BackupDocument.self, from: data)
    }

    // MARK: - Validation (pure)

    /// Cross-reference and semantic checks beyond JSON decoding. Every
    /// finding is reported before any database mutation, so a rejected file
    /// never leaves partial state.
    static func validateSemantics(of document: BackupDocument) throws {
        var recipeIDs = Set<UUID>()
        var recipeStepIDs: [UUID: Set<UUID>] = [:]
        var recipeStepCounts: [UUID: Int] = [:]
        for stored in document.recipes {
            let path = "recipe \(stored.id.uuidString)"
            guard recipeIDs.insert(stored.id).inserted else {
                throw DataTransferError.invalidItem(path: path, reason: "duplicate recipe ID in file.")
            }
            guard validText(stored.title) else {
                throw DataTransferError.invalidItem(path: path, reason: "title is blank.")
            }
            guard stored.servings.isFinite, stored.servings > 0 else {
                throw DataTransferError.invalidItem(path: path, reason: "servings must be finite and > 0.")
            }
            guard !stored.ingredients.isEmpty, !stored.steps.isEmpty else {
                throw DataTransferError.invalidItem(path: path, reason: "ingredients and steps must be non-empty.")
            }
            var ingredientIDs = Set<UUID>()
            for (index, ingredient) in stored.ingredients.enumerated() {
                let itemPath = "\(path) ingredient[\(index)]"
                guard ingredientIDs.insert(ingredient.id).inserted else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "duplicate ingredient ID.")
                }
                guard IngredientUnit(rawValue: ingredient.unit) != nil else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "unknown unit '\(ingredient.unit)'.")
                }
                guard validText(ingredient.name) else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "name is blank.")
                }
                guard ingredient.amount.isFinite, ingredient.amount > 0 else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "amount must be finite and > 0.")
                }
            }
            var stepIDs = Set<UUID>()
            for (index, step) in stored.steps.enumerated() {
                let itemPath = "\(path) step[\(index)]"
                guard stepIDs.insert(step.id).inserted else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "duplicate step ID.")
                }
                guard validText(step.instruction) else {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "instruction is blank.")
                }
                if let duration = step.timerDuration, !duration.isFinite || duration <= 0 {
                    throw DataTransferError.invalidItem(path: itemPath, reason: "timer duration must be finite and > 0.")
                }
            }
            recipeStepIDs[stored.id] = stepIDs
            recipeStepCounts[stored.id] = stored.steps.count
        }

        var sessionIDs = Set<UUID>()
        for stored in document.sessions {
            let path = "session \(stored.id.uuidString)"
            guard sessionIDs.insert(stored.id).inserted else {
                throw DataTransferError.invalidItem(path: path, reason: "duplicate session ID in file.")
            }
            guard recipeIDs.contains(stored.recipeID) else {
                throw DataTransferError.invalidItem(
                    path: path,
                    reason: "references unknown recipe \(stored.recipeID.uuidString)."
                )
            }
            guard CookSessionStatus(rawValue: stored.status) != nil else {
                throw DataTransferError.invalidItem(path: path, reason: "unknown status '\(stored.status)'.")
            }
            let stepCount = recipeStepCounts[stored.recipeID] ?? 0
            guard stepCount > 0, stored.currentStepIndex >= 0, stored.currentStepIndex < stepCount else {
                throw DataTransferError.invalidItem(
                    path: path,
                    reason: "current step \(stored.currentStepIndex) is outside the recipe."
                )
            }
        }

        var timerIDs = Set<UUID>()
        for stored in document.timers {
            let path = "timer \(stored.id.uuidString)"
            guard timerIDs.insert(stored.id).inserted else {
                throw DataTransferError.invalidItem(path: path, reason: "duplicate timer ID in file.")
            }
            guard let steps = recipeStepIDs[stored.recipeID], steps.contains(stored.stepID) else {
                throw DataTransferError.invalidItem(
                    path: path,
                    reason: "references unknown step \(stored.stepID.uuidString) of recipe \(stored.recipeID.uuidString)."
                )
            }
            guard sessionIDs.contains(stored.cookSessionID) else {
                throw DataTransferError.invalidItem(
                    path: path,
                    reason: "references unknown cook session \(stored.cookSessionID.uuidString)."
                )
            }
            guard let status = CookTimerStatus(rawValue: stored.status) else {
                throw DataTransferError.invalidItem(path: path, reason: "unknown status '\(stored.status)'.")
            }
            guard stored.originalDuration.isFinite, stored.originalDuration > 0 else {
                throw DataTransferError.invalidItem(path: path, reason: "duration must be finite and > 0.")
            }
            guard validText(stored.stepName) else {
                throw DataTransferError.invalidItem(path: path, reason: "step name is blank.")
            }
            // Mirror the cook_timers_valid_shape trigger so bad timer rows
            // surface as per-item findings instead of aborting mid-write.
            switch status {
            case .running:
                guard stored.deadline != nil,
                      stored.remainingWhenPaused == nil,
                      stored.completedAt == nil
                else {
                    throw DataTransferError.invalidItem(
                        path: path,
                        reason: "running timers must carry a deadline and no remaining/completed fields."
                    )
                }
            case .paused:
                guard stored.deadline == nil,
                      let remaining = stored.remainingWhenPaused,
                      remaining.isFinite, remaining > 0,
                      stored.completedAt == nil
                else {
                    throw DataTransferError.invalidItem(
                        path: path,
                        reason: "paused timers must carry positive remaining time and no deadline/completed fields."
                    )
                }
            case .cancelled, .completed:
                guard stored.deadline == nil,
                      stored.remainingWhenPaused == nil,
                      stored.completedAt != nil
                else {
                    throw DataTransferError.invalidItem(
                        path: path,
                        reason: "ended timers must carry a completion time and no deadline/paused fields."
                    )
                }
            }
        }

        for stored in document.timerEvents {
            let path = "timer event \(stored.id.uuidString)"
            guard timerIDs.contains(stored.timerID) else {
                throw DataTransferError.invalidItem(
                    path: path,
                    reason: "references unknown timer \(stored.timerID.uuidString)."
                )
            }
            guard let kind = TimerEventKind(rawValue: stored.kind) else {
                throw DataTransferError.invalidItem(path: path, reason: "unknown event kind '\(stored.kind)'.")
            }
            if kind == .extended {
                guard let seconds = stored.seconds, seconds.isFinite, seconds != 0 else {
                    throw DataTransferError.invalidItem(path: path, reason: "extended event needs a non-zero seconds value.")
                }
            }
        }
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Snapshot reads

    private static func readSnapshot(
        _ db: Database
    ) throws -> (
        recipes: [BackupDocument.StoredRecipe],
        sessions: [BackupDocument.StoredSession],
        timers: [BackupDocument.StoredTimer],
        timerEvents: [BackupDocument.StoredTimerEvent]
    ) {
        let recipeRows = try Row.fetchAll(
            db,
            sql: "SELECT id, title, servings, is_favorite FROM recipes ORDER BY rowid"
        )
        var recipes: [BackupDocument.StoredRecipe] = []
        for row in recipeRows {
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw RecipeRepositoryError.corruptData("Invalid recipe ID \(idString).")
            }
            let ingredientRows = try Row.fetchAll(
                db,
                sql: "SELECT id, name, amount, unit FROM ingredients WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            )
            let stepRows = try Row.fetchAll(
                db,
                sql: "SELECT id, instruction, timer_duration FROM recipe_steps WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            )
            let tags = try String.fetchAll(
                db,
                sql: "SELECT name FROM recipe_tags WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            )
            recipes.append(BackupDocument.StoredRecipe(
                id: id,
                title: row["title"],
                servings: row["servings"],
                isFavorite: row["is_favorite"],
                tags: tags,
                ingredients: try ingredientRows.map { ingredientRow in
                    let ingredientIDString: String = ingredientRow["id"]
                    guard let ingredientID = UUID(uuidString: ingredientIDString) else {
                        throw RecipeRepositoryError.corruptData("Invalid ingredient ID \(ingredientIDString).")
                    }
                    return BackupDocument.StoredIngredient(
                        id: ingredientID,
                        name: ingredientRow["name"],
                        amount: ingredientRow["amount"],
                        unit: ingredientRow["unit"]
                    )
                },
                steps: try stepRows.map { stepRow in
                    let stepIDString: String = stepRow["id"]
                    guard let stepID = UUID(uuidString: stepIDString) else {
                        throw RecipeRepositoryError.corruptData("Invalid step ID \(stepIDString).")
                    }
                    return BackupDocument.StoredStep(
                        id: stepID,
                        instruction: stepRow["instruction"],
                        timerDuration: stepRow["timer_duration"]
                    )
                }
            ))
        }

        let sessions = try Row.fetchAll(
            db,
            sql: """
                SELECT id, recipe_id, started_at, ended_at, status, current_step
                FROM cook_sessions ORDER BY started_at, id
                """
        ).map { row -> BackupDocument.StoredSession in
            let idString: String = row["id"]
            let recipeString: String = row["recipe_id"]
            guard let id = UUID(uuidString: idString), let recipeID = UUID(uuidString: recipeString) else {
                throw RecipeRepositoryError.corruptData("Invalid session ID \(idString).")
            }
            return BackupDocument.StoredSession(
                id: id,
                recipeID: recipeID,
                startedAt: row["started_at"],
                endedAt: row["ended_at"],
                status: row["status"],
                currentStepIndex: row["current_step"]
            )
        }

        let timers = try Row.fetchAll(
            db,
            sql: """
                SELECT id, recipe_id, step_id, cook_session_id, step_name,
                       original_duration, status, started_at, deadline,
                       remaining_when_paused, completed_at
                FROM cook_timers ORDER BY started_at, id
                """
        ).map { row -> BackupDocument.StoredTimer in
            let idString: String = row["id"]
            let recipeString: String = row["recipe_id"]
            let stepString: String = row["step_id"]
            let sessionString: String = row["cook_session_id"]
            guard let id = UUID(uuidString: idString),
                  let recipeID = UUID(uuidString: recipeString),
                  let stepID = UUID(uuidString: stepString),
                  let sessionID = UUID(uuidString: sessionString)
            else {
                throw RecipeRepositoryError.corruptData("Invalid timer ID \(idString).")
            }
            return BackupDocument.StoredTimer(
                id: id,
                recipeID: recipeID,
                stepID: stepID,
                cookSessionID: sessionID,
                stepName: row["step_name"],
                originalDuration: row["original_duration"],
                status: row["status"],
                startedAt: row["started_at"],
                deadline: row["deadline"],
                remainingWhenPaused: row["remaining_when_paused"],
                completedAt: row["completed_at"]
            )
        }

        let timerEvents = try Row.fetchAll(
            db,
            sql: "SELECT id, timer_id, event_kind, occurred_at, seconds FROM timer_events ORDER BY sequence"
        ).map { row -> BackupDocument.StoredTimerEvent in
            let idString: String = row["id"]
            let timerString: String = row["timer_id"]
            guard let id = UUID(uuidString: idString), let timerID = UUID(uuidString: timerString) else {
                throw RecipeRepositoryError.corruptData("Invalid timer event ID \(idString).")
            }
            return BackupDocument.StoredTimerEvent(
                id: id,
                timerID: timerID,
                kind: row["event_kind"],
                occurredAt: row["occurred_at"],
                seconds: row["seconds"]
            )
        }

        return (recipes, sessions, timers, timerEvents)
    }

    // MARK: - Merge writes

    private static func decodedRecipe(_ stored: BackupDocument.StoredRecipe) throws -> Recipe {
        try Recipe(
            id: stored.id,
            title: stored.title,
            servings: stored.servings,
            ingredients: stored.ingredients.map { ingredient in
                try Ingredient(
                    id: ingredient.id,
                    name: ingredient.name,
                    amount: ingredient.amount,
                    unit: IngredientUnit(rawValue: ingredient.unit) ?? .each
                )
            },
            steps: stored.steps.map { step in
                try RecipeStep(
                    id: step.id,
                    instruction: step.instruction,
                    timerDuration: step.timerDuration
                )
            },
            tags: stored.tags,
            isFavorite: stored.isFavorite
        )
    }

    /// Rebuilds the stored recipe for a canonical equality comparison
    /// against the validated incoming copy. Returns nil if the stored row
    /// is unreadable (treated as "different" -> replace).
    private static func storedRecipe(_ db: Database, id: UUID) throws -> Recipe? {
        let idString = id.uuidString
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT title, servings, is_favorite FROM recipes WHERE id = ?",
            arguments: [idString]
        ) else { return nil }
        let stored = BackupDocument.StoredRecipe(
            id: id,
            title: row["title"],
            servings: row["servings"],
            isFavorite: row["is_favorite"],
            tags: try String.fetchAll(
                db,
                sql: "SELECT name FROM recipe_tags WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            ),
            ingredients: try Row.fetchAll(
                db,
                sql: "SELECT id, name, amount, unit FROM ingredients WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            ).map { row in
                BackupDocument.StoredIngredient(
                    id: UUID(uuidString: row["id"]) ?? UUID(),
                    name: row["name"],
                    amount: row["amount"],
                    unit: row["unit"]
                )
            },
            steps: try Row.fetchAll(
                db,
                sql: "SELECT id, instruction, timer_duration FROM recipe_steps WHERE recipe_id = ? ORDER BY position",
                arguments: [idString]
            ).map { row in
                BackupDocument.StoredStep(
                    id: UUID(uuidString: row["id"]) ?? UUID(),
                    instruction: row["instruction"],
                    timerDuration: row["timer_duration"]
                )
            }
        )
        return try? decodedRecipe(stored)
    }

    private static func insertRecipe(_ db: Database, _ recipe: Recipe) throws {
        try db.execute(
            sql: "INSERT INTO recipes (id, title, servings, is_favorite) VALUES (?, ?, ?, ?)",
            arguments: [recipe.id.uuidString, recipe.title, recipe.servings, recipe.isFavorite]
        )
        try insertRecipeChildren(db, recipe)
    }

    /// Replace-in-place: mirrors `RecipeRepository.update` semantics but
    /// stays inside the import transaction. Active cook sessions clamp their
    /// step the same way the regular update path does.
    private static func replaceRecipe(_ db: Database, with recipe: Recipe) throws {
        try db.execute(
            sql: "UPDATE recipes SET title = ?, servings = ?, is_favorite = ? WHERE id = ?",
            arguments: [recipe.title, recipe.servings, recipe.isFavorite, recipe.id.uuidString]
        )
        try db.execute(sql: "DELETE FROM ingredients WHERE recipe_id = ?", arguments: [recipe.id.uuidString])
        try db.execute(sql: "DELETE FROM recipe_steps WHERE recipe_id = ?", arguments: [recipe.id.uuidString])
        try db.execute(sql: "DELETE FROM recipe_tags WHERE recipe_id = ?", arguments: [recipe.id.uuidString])
        try insertRecipeChildren(db, recipe)
        try db.execute(
            sql: """
                UPDATE cook_sessions
                SET current_step = ?
                WHERE recipe_id = ? AND status = 'active' AND current_step >= ?
                """,
            arguments: [recipe.steps.count - 1, recipe.id.uuidString, recipe.steps.count]
        )
    }

    private static func insertRecipeChildren(_ db: Database, _ recipe: Recipe) throws {
        for (position, ingredient) in recipe.ingredients.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO ingredients (id, recipe_id, position, name, amount, unit)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    ingredient.id.uuidString, recipe.id.uuidString, position,
                    ingredient.name, ingredient.amount, ingredient.unit.rawValue,
                ]
            )
        }
        for (position, step) in recipe.steps.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO recipe_steps (id, recipe_id, position, instruction, timer_duration)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    step.id.uuidString, recipe.id.uuidString, position,
                    step.instruction, step.timerDuration,
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
}
