import XCTest
import GRDB

@testable import CookConsole

/// Issue #6: user-owned JSON/CSV export, validated import, and the
/// merge-not-clobber policy. These exercise the real GRDB store (in-memory),
/// the real trigger set, and the real domain validation — the same code the
/// "Your data" screen calls.
final class DataTransferServiceTests: XCTestCase {
    // MARK: - Fixtures

    private func makeService(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> (DataTransferService, DatabaseQueue, RecipeRepository) {
        let database = try RecipeDatabase.makeInMemory()
        let service = DataTransferService(
            database: database,
            appVersion: "9.9 (build 9)",
            now: { now }
        )
        return (service, database, RecipeRepository(database: database))
    }

    private func sampleRecipe(
        title: String = "Weeknight Chili",
        servings: Double = 4,
        withTimer: Bool = true
    ) throws -> Recipe {
        try Recipe(
            title: title,
            servings: servings,
            ingredients: [
                Ingredient(name: "Black beans", amount: 2, unit: .cup),
                Ingredient(name: "Tomato paste", amount: 2, unit: .tablespoon),
            ],
            steps: [
                RecipeStep(instruction: "Sauté aromatics."),
                RecipeStep(
                    instruction: "Simmer covered.",
                    timerDuration: withTimer ? 2_700 : nil
                ),
            ],
            tags: ["dinner", "batch"],
            isFavorite: true
        )
    }

    /// Seeds one recipe, one completed cook session for it, and one fired
    /// step timer (+ started/extended events) through the same trigger-gated
    /// writes the app uses, ending in the exact durable shape the app leaves
    /// behind: completed session, completed timer, event log.
    @discardableResult
    private func seedHistory(
        into database: DatabaseQueue,
        repository: RecipeRepository,
        recipe: Recipe,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> (CookSession, CookTimer) {
        try repository.create(recipe)
        let session = try repository.beginCook(for: recipe.id, at: startedAt)
        try repository.updateCookPosition(sessionID: session.id, to: 1)

        let stepID = recipe.steps[1].id
        let timerID = UUID()
        let timerStarted = startedAt.addingTimeInterval(600)
        let deadline = timerStarted.addingTimeInterval(2_700)
        let completedAt = deadline.addingTimeInterval(2)

        // The running timer first (valid identity: the session is active).
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cook_timers
                        (id, recipe_id, step_id, cook_session_id, step_name,
                         original_duration, status, started_at, deadline,
                         remaining_when_paused, completed_at, schedule_generation)
                    VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, NULL, NULL, 1)
                    """,
                arguments: [
                    timerID.uuidString, recipe.id.uuidString, stepID.uuidString,
                    session.id.uuidString, "2: Simmer covered.", 2_700,
                    timerStarted, deadline,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO timer_events (id, timer_id, event_kind, occurred_at, seconds)
                    VALUES (?, ?, 'started', ?, NULL)
                    """,
                arguments: [UUID().uuidString, timerID.uuidString, timerStarted]
            )
            try db.execute(
                sql: """
                    INSERT INTO timer_events (id, timer_id, event_kind, occurred_at, seconds)
                    VALUES (?, ?, 'extended', ?, 120)
                    """,
                arguments: [UUID().uuidString, timerID.uuidString, timerStarted.addingTimeInterval(300)]
            )
        }
        // Fire it: completed shape while the session is still active.
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_timers
                    SET status = 'completed', deadline = NULL, completed_at = ?
                    WHERE id = ?
                    """,
                arguments: [completedAt, timerID.uuidString]
            )
        }
        try repository.endCook(sessionID: session.id, as: .completed, at: completedAt)

        let storedSession = try XCTUnwrap(repository.fetchCookSession(id: session.id))
        let storedTimer = try XCTUnwrap(TimerRepository(database: database).fetchTimer(id: timerID))
        return (storedSession, storedTimer)
    }

    // MARK: - Export

    func testExportDocumentContainsVersionedHeaderWithProvenance() throws {
        let (service, database, repository) = try makeService()
        _ = try seedHistory(into: database, repository: repository, recipe: sampleRecipe())

        let document = try service.exportDocument()
        XCTAssertEqual(document.header.schemaVersion, BackupDocument.currentSchemaVersion)
        XCTAssertEqual(document.header.appVersion, "9.9 (build 9)")
        XCTAssertEqual(document.header.exportedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(document.recipes.count, 1)
        XCTAssertEqual(document.sessions.count, 1)
        XCTAssertEqual(document.timers.count, 1)
        XCTAssertEqual(document.timerEvents.count, 2)
    }

    func testExportRoundTripsThroughEncodedJSON() throws {
        let (service, database, repository) = try makeService()
        _ = try seedHistory(into: database, repository: repository, recipe: sampleRecipe())

        let document = try service.exportDocument()
        let data = try service.encodedData(for: document)
        let decoded = try service.decodedDocument(from: data)
        XCTAssertEqual(decoded, document)
    }

    // MARK: - Round-trip fidelity

    func testImportIntoEmptyStoreReproducesTheFullLibrary() throws {
        let (sourceService, sourceDatabase, sourceRepo) = try makeService()
        let recipe = try sampleRecipe()
        let (session, timer) = try seedHistory(
            into: sourceDatabase,
            repository: sourceRepo,
            recipe: recipe
        )

        let document = try sourceService.exportDocument()
        let data = try sourceService.encodedData(for: document)

        // Restore into a clean store — the phone-replacement scenario.
        let (targetService, targetDatabase, targetRepo) = try makeService()
        let decoded = try sourceService.decodedDocument(from: data)
        let outcome = try targetService.applyValidated(decoded)

        XCTAssertEqual(outcome.recipesAdded, 1)
        XCTAssertEqual(outcome.recipesReplaced, 0)
        XCTAssertEqual(outcome.sessionsAdded, 1)
        XCTAssertEqual(outcome.timersAdded, 1)
        XCTAssertEqual(outcome.timersSkipped, 0)

        // Fidelity: domain values come back equal.
        let restored = try XCTUnwrap(targetRepo.fetch(id: recipe.id))
        XCTAssertEqual(restored, recipe)
        let restoredSession = try XCTUnwrap(targetRepo.fetchCookSession(id: session.id))
        XCTAssertEqual(restoredSession, session)
        let restoredTimer = try XCTUnwrap(
            TimerRepository(database: targetDatabase).fetchTimer(id: timer.id)
        )
        XCTAssertEqual(restoredTimer, timer)
        XCTAssertEqual(
            try TimerRepository(database: targetDatabase).fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .extended]
        )

        // Export -> import -> export is stable (modulo header provenance).
        let reExported = try targetService.exportDocument()
        var left = document
        let right = reExported
        left.header = right.header
        XCTAssertEqual(left, right)
    }

    // MARK: - Merge-not-clobber

    func testReimportOfIdenticalBackupChangesNothing() throws {
        let (service, database, repository) = try makeService()
        _ = try seedHistory(into: database, repository: repository, recipe: sampleRecipe())

        let document = try service.exportDocument()
        let data = try service.encodedData(for: document)
        let decoded = try service.decodedDocument(from: data)

        let outcome = try service.applyValidated(decoded)
        XCTAssertEqual(outcome.recipesAdded, 0)
        XCTAssertEqual(outcome.recipesSkipped, 1)
        XCTAssertEqual(outcome.recipesReplaced, 0)
        XCTAssertEqual(outcome.sessionsAdded, 0)
        XCTAssertEqual(outcome.sessionsSkipped, 1)
        XCTAssertEqual(outcome.timersSkipped, 1)
        XCTAssertEqual(outcome.timersAdded, 0)

        // Row-for-row stability: the second export equals the first exactly.
        let after = try service.exportDocument()
        XCTAssertEqual(after.recipes, document.recipes)
        XCTAssertEqual(after.sessions, document.sessions)
        XCTAssertEqual(after.timers, document.timers)
        XCTAssertEqual(after.timerEvents, document.timerEvents)
    }

    func testImportReplacesExistingRecipeIDWithIncomingCopyAndAddsNewOnes() throws {
        let (service, _, repository) = try makeService()
        let original = try sampleRecipe()
        try repository.create(original)

        // An edited version of the SAME id plus a brand-new recipe.
        let edited = try Recipe(
            id: original.id,
            title: "Weeknight Chili (Extra Bean)",
            servings: 6,
            ingredients: original.ingredients,
            steps: original.steps,
            tags: ["dinner"],
            isFavorite: false
        )
        let newcomer = try sampleRecipe(title: "Pantry Soup", servings: 2, withTimer: false)
        let document = BackupDocument(
            header: .init(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 1),
                appVersion: "old"
            ),
            recipes: [
                storedCopy(of: edited),
                storedCopy(of: newcomer),
            ],
            sessions: [],
            timers: [],
            timerEvents: []
        )

        let outcome = try service.applyValidated(document)
        XCTAssertEqual(outcome.recipesReplaced, 1)
        XCTAssertEqual(outcome.recipesAdded, 1)
        XCTAssertEqual(outcome.recipesSkipped, 0)

        let stored = try repository.fetchAll()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(try XCTUnwrap(repository.fetch(id: original.id)), edited)
        XCTAssertEqual(try XCTUnwrap(repository.fetch(id: newcomer.id)), newcomer)
    }

    func testSessionReferencingUnknownRecipeFailsWithZeroWrites() throws {
        let (service, _, repository) = try makeService()
        let document = BackupDocument(
            header: .init(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 1),
                appVersion: "old"
            ),
            recipes: [],
            sessions: [.init(
                id: UUID(),
                recipeID: UUID(), // exists nowhere
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: nil,
                status: "active",
                currentStepIndex: 0
            )],
            timers: [],
            timerEvents: []
        )

        XCTAssertThrowsError(try service.applyValidated(document)) { error in
            guard case DataTransferError.invalidItem(_, let reason)? = error as? DataTransferError else {
                return XCTFail("Expected invalidItem about the missing recipe, got \(error)")
            }
            XCTAssertTrue(reason.contains("references recipe"), reason)
        }
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testFailureMidFileRollsBackAllEarlierWrites() throws {
        let (service, _, repository) = try makeService()
        let good = try storedCopy(of: sampleRecipe())
        var broken = good
        broken.title = "   " // blank after trimming -> domain rejects

        let document = BackupDocument(
            header: .init(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 1),
                appVersion: "old"
            ),
            recipes: [good, broken],
            sessions: [],
            timers: [],
            timerEvents: []
        )

        XCTAssertThrowsError(try service.applyValidated(document))
        // The first recipe was written earlier in the same transaction and
        // must not survive the failure on the second one.
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testUnsupportedSchemaVersionIsRejectedWithoutWrites() throws {
        let (service, _, repository) = try makeService()
        let url = try writeFile(
            #"{"header":{"schemaVersion":999,"exportedAt":"2026-01-01T00:00:00.000Z","appVersion":"future"},"recipes":[],"sessions":[],"timers":[],"timerEvents":[]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try service.validateDocument(at: url)) { error in
            XCTAssertEqual(
                error as? DataTransferError,
                .unsupportedSchemaVersion(999)
            )
        }
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testMalformedFileIsRejected() throws {
        let (service, _, _) = try makeService()
        let url = try writeFile("this is not json {{{")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try service.validateDocument(at: url)) { error in
            guard case DataTransferError.malformed? = error as? DataTransferError else {
                return XCTFail("Expected malformed, got \(error)")
            }
        }
    }

    func testValidationReportsInvalidItemPathForBadIngredientAmount() throws {
        let document = BackupDocument(
            header: .init(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 1),
                appVersion: "x"
            ),
            recipes: [.init(
                id: UUID(),
                title: "Broken Soup",
                servings: 2,
                isFavorite: false,
                tags: [],
                ingredients: [.init(id: UUID(), name: "Water", amount: -1, unit: "cup")],
                steps: [.init(id: UUID(), instruction: "Boil.", timerDuration: nil)]
            )],
            sessions: [],
            timers: [],
            timerEvents: []
        )

        XCTAssertThrowsError(try DataTransferService.validateSemantics(of: document)) { error in
            guard case DataTransferError.invalidItem(let path, let reason)? = error as? DataTransferError else {
                return XCTFail("Expected invalidItem, got \(error)")
            }
            XCTAssertTrue(path.contains("ingredient[0]"), path)
            XCTAssertTrue(reason.contains("amount"), reason)
        }
    }

    func testRunningTimerWithoutDeadlineIsRejected() throws {
        let recipe = try sampleRecipe()
        let document = BackupDocument(
            header: .init(
                schemaVersion: BackupDocument.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 1),
                appVersion: "x"
            ),
            recipes: [storedCopy(of: recipe)],
            sessions: [.init(
                id: UUID(),
                recipeID: recipe.id,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: nil,
                status: "active",
                currentStepIndex: 0
            )],
            timers: [.init(
                id: UUID(),
                recipeID: recipe.id,
                stepID: recipe.steps[1].id,
                cookSessionID: UUID(), // repaired below; the deadline is the defect under test
                stepName: "2: Simmer covered.",
                originalDuration: 2_700,
                status: "running",
                startedAt: Date(timeIntervalSince1970: 20),
                deadline: nil,
                remainingWhenPaused: nil,
                completedAt: nil
            )],
            timerEvents: []
        )
        var fixed = document
        fixed.timers[0].cookSessionID = document.sessions[0].id

        XCTAssertThrowsError(try DataTransferService.validateSemantics(of: fixed)) { error in
            guard case DataTransferError.invalidItem(_, let reason)? = error as? DataTransferError else {
                return XCTFail("Expected invalidItem, got \(error)")
            }
            XCTAssertTrue(reason.contains("deadline"), reason)
        }
    }

    // MARK: - CSV

    func testHistoryCSVHeadersRowsAndQuoting() throws {
        let (service, database, repository) = try makeService()
        let tricky = try sampleRecipe(title: "Chili, \"extra\" hot")
        let (session, _) = try seedHistory(into: database, repository: repository, recipe: tricky)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cook-console-history-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try service.writeHistoryCSV(to: url)

        let contents = try XCTUnwrap(String(contentsOf: url, encoding: .utf8))
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            lines.first.map(String.init),
            "session_id,recipe_id,recipe_title,status,started_at,ended_at,current_step,step_count"
        )

        // One data row; the title stays ONE field via RFC-4180 quoting even
        // though it contains a comma and quotes.
        XCTAssertTrue(contents.contains("\"Chili, \"\"extra\"\" hot\""), contents)
        XCTAssertTrue(contents.contains(session.id.uuidString))
        XCTAssertTrue(contents.contains(",completed,"))
    }

    func testCSVLineQuotingRules() {
        XCTAssertEqual(DataTransferService.csvLine(["plain", "4"]), "plain,4")
        XCTAssertEqual(DataTransferService.csvLine(["a,b", "c\"d"]), "\"a,b\",\"c\"\"d\"")
        XCTAssertEqual(DataTransferService.csvLine(["multi\nline"]), "\"multi\nline\"")
    }

    // MARK: - Helpers

    private func storedCopy(of recipe: Recipe) -> BackupDocument.StoredRecipe {
        BackupDocument.StoredRecipe(
            id: recipe.id,
            title: recipe.title,
            servings: recipe.servings,
            isFavorite: recipe.isFavorite,
            tags: recipe.tags,
            ingredients: recipe.ingredients.map {
                .init(id: $0.id, name: $0.name, amount: $0.amount, unit: $0.unit.rawValue)
            },
            steps: recipe.steps.map {
                .init(id: $0.id, instruction: $0.instruction, timerDuration: $0.timerDuration)
            }
        )
    }

    private func writeFile(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cook-console-import-test-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
