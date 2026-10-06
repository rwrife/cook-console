import XCTest
import GRDB

@testable import CookConsole

/// Issue #6: user-owned JSON/CSV export, validated import, and the
/// merge-not-clobber policy. These exercise the real GRDB store (in-memory),
/// the real trigger set, and the real domain validation — the same code the
/// "Your data" screen calls.
final class DataTransferServiceTests: XCTestCase {
    func testRecipeOnlyPreviewReportsLiveReplacementAndArchiveMutations() throws {
        for archive in [false, true] {
            let (service, database, repository) = try makeService()
            let recipe = try sampleRecipe()
            let (session, timer) = try seedHistory(into: database, repository: repository, recipe: recipe)
            try database.write { db in
                try db.execute(sql: "UPDATE cook_sessions SET status = 'active', ended_at = NULL WHERE id = ?", arguments: [session.id.uuidString])
                try db.execute(sql: "UPDATE cook_timers SET status = 'running', completed_at = NULL, deadline = ? WHERE id = ?", arguments: [Date().addingTimeInterval(600), timer.id.uuidString])
            }
            let timers = TimerRepository(database: database)
            let notifications = ImportNotificationScheduler()
            let engine = TimerEngine(repository: timers, notifications: notifications)
            let paused = try engine.start(recipeID: recipe.id, stepID: recipe.steps[1].id,
                                          cookSessionID: session.id, stepName: "Paused removed step", duration: 600)
            _ = try engine.pause(timerID: paused.id)
            _ = try GroceryRepository(database: database).addSelection(recipeID: recipe.id, servings: 2)
            try database.write { db in
                for id in [timer.id, paused.id] {
                    try db.execute(sql: "INSERT INTO timer_completion_alerts (timer_id, completed_at) VALUES (?, ?)",
                                   arguments: [id.uuidString, Date()])
                }
            }
            var incoming = try service.exportDocument()
            incoming.header.exportedAt = Date(timeIntervalSince1970: 1_000)
            incoming.recipes[0].steps = [incoming.recipes[0].steps[0]]
            incoming.recipes[0].deletedAt = archive ? Date(timeIntervalSince1970: 2_000) : nil
            incoming.sessions = []
            incoming.timers = []
            incoming.timerEvents = []
            incoming.grocerySelections = nil
            incoming.groceryManualItems = nil
            func snapshot() throws -> [[String]] {
                try database.read { db in
                    try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                        .map { table in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description) }
                }
            }
            let before = try snapshot()
            let preview = try service.preview(incoming)
            XCTAssertEqual(preview.outcome.existingLiveTimersStopped, 2)
            XCTAssertEqual(preview.outcome.completionAlertsRemoved, 2)
            XCTAssertEqual(preview.outcome.activeSessionsClamped, 1)
            XCTAssertEqual(preview.outcome.activeSessionsAbandoned, archive ? 1 : 0)
            XCTAssertEqual(preview.outcome.grocerySelectionsRemoved, archive ? 1 : 0)
            XCTAssertTrue(preview.outcome.summaryText.contains("2 existing live timers stopped"))
            XCTAssertTrue(preview.outcome.summaryText.contains("2 completion alerts removed"))
            XCTAssertTrue(preview.outcome.summaryText.contains("1 active cook sessions clamped"))
            if archive {
                XCTAssertTrue(preview.outcome.summaryText.contains("1 active cook sessions abandoned"))
                XCTAssertTrue(preview.outcome.summaryText.contains("1 grocery selections removed"))
            }
            XCTAssertEqual(try snapshot(), before) // Discarding the preview is cancellation.
            XCTAssertEqual(try service.apply(preview), preview.outcome)
            XCTAssertEqual(try timers.fetchTimer(id: timer.id)?.status, .cancelled)
            XCTAssertEqual(try timers.fetchTimer(id: paused.id)?.status, .cancelled)
            XCTAssertEqual(try repository.fetchCookSession(id: session.id)?.currentStepIndex, 0)
            XCTAssertEqual(try repository.fetchCookSession(id: session.id)?.status, archive ? .abandoned : .active)
            XCTAssertTrue(try engine.pendingCompletions().isEmpty)
            // AppStore.refreshAfterRecovery invokes this same synchronization.
            notifications.removed.removeAll()
            try engine.synchronizeNotifications()
            XCTAssertEqual(Set(notifications.removed), Set([timer.id, paused.id]))
            XCTAssertTrue(notifications.scheduled.isEmpty)
            XCTAssertEqual(try GroceryRepository(database: database).fetchSelections().count, archive ? 0 : 1)
        }
    }

    func testEditorRemovedStepTimersExportAsHistoryWithoutMutatingLiveStore() throws {
        for paused in [false, true] {
            let (service, database, repository) = try makeService()
            let recipe = try sampleRecipe()
            let (_, historical) = try seedHistory(into: database, repository: repository, recipe: recipe)
            let session = try repository.beginCook(for: recipe.id, at: Date(timeIntervalSince1970: 1_700_004_000))
            let timers = TimerRepository(database: database)
            let engine = TimerEngine(repository: timers, notifications: NoopTimerNotificationScheduler(),
                                     now: { Date(timeIntervalSince1970: 1_700_004_000) })
            let removed = try engine.start(recipeID: recipe.id, stepID: recipe.steps[1].id,
                                           cookSessionID: session.id, stepName: "Original simmer snapshot", duration: 2700)
            if paused { _ = try engine.pause(timerID: removed.id) }
            let retained = try engine.start(recipeID: recipe.id, stepID: recipe.steps[0].id,
                                            cookSessionID: session.id, stepName: "Retained step", duration: 600)
            try database.write { db in
                try db.execute(sql: "INSERT INTO timer_completion_alerts (timer_id, completed_at) VALUES (?, ?)",
                               arguments: [historical.id.uuidString, historical.completedAt])
            }
            let edited = try Recipe(id: recipe.id, title: recipe.title, servings: recipe.servings,
                                    ingredients: recipe.ingredients, steps: [recipe.steps[0]],
                                    tags: recipe.tags, isFavorite: recipe.isFavorite)
            try repository.update(edited) // The ordinary editor path, preserving #4's live snapshot policy.
            let before = try database.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                    .map { table in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description) }
            }
            let live = try XCTUnwrap(timers.fetchTimer(id: removed.id))
            XCTAssertEqual(live.status, paused ? .paused : .running)
            let document = try service.exportDocument()
            let exported = try XCTUnwrap(document.timers.first { $0.id == removed.id })
            XCTAssertEqual(exported.status, "cancelled")
            XCTAssertEqual(exported.completedAt, document.header.exportedAt)
            XCTAssertNil(exported.deadline)
            XCTAssertNil(exported.remainingWhenPaused)
            XCTAssertEqual(exported.stepID, removed.stepID)
            XCTAssertEqual(exported.stepName, removed.stepName)
            XCTAssertEqual(document.timers.first { $0.id == retained.id }?.status, "running")
            XCTAssertEqual(document.timers.first { $0.id == historical.id }?.status, "completed")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            try service.writeJSONBackup(to: url)
            XCTAssertEqual(try service.validateDocument(at: url), document)
            let decoded = try service.decodedDocument(from: service.encodedData(for: document))
            let (clean, recoveredDB, recoveredRecipes) = try makeService()
            let preview = try clean.preview(decoded)
            XCTAssertTrue(try recoveredRecipes.fetchAll().isEmpty)
            _ = try clean.apply(preview)
            XCTAssertEqual(try clean.exportDocument(), document)
            XCTAssertEqual(try TimerRepository(database: recoveredDB).fetchTimer(id: removed.id)?.status, .cancelled)
            XCTAssertEqual(try recoveredDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM timer_completion_alerts") }, 0)
            XCTAssertEqual(try timers.fetchTimer(id: removed.id), live)
            let after = try database.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                    .map { table in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description) }
            }
            XCTAssertEqual(after, before) // Includes event history, generations, metadata, and pending alerts.
        }
    }

    func testReplacementWithRemovedHistoricalStepRoundTripsIntoCleanStore() throws {
        let (service, database, repository) = try makeService()
        let recipe = try sampleRecipe()
        _ = try seedHistory(into: database, repository: repository, recipe: recipe)
        var incoming = try service.exportDocument()
        incoming.recipes[0].steps = [incoming.recipes[0].steps[0]]
        incoming.sessions = []
        incoming.timers = []
        incoming.timerEvents = []
        _ = try service.apply(try service.preview(incoming))
        let backup = try service.exportDocument()
        XCTAssertEqual(backup.recipes[0].steps.count, 1)
        XCTAssertEqual(backup.sessions[0].currentStepIndex, 1)
        XCTAssertEqual(backup.timers[0].stepID, recipe.steps[1].id)
        let (clean, _, recovered) = try makeService()
        _ = try clean.apply(try clean.preview(backup))
        XCTAssertEqual(try recovered.fetch(id: recipe.id)?.steps.count, 1)
        XCTAssertEqual(try clean.exportDocument().timers, backup.timers)

        var invalid = backup
        invalid.timers[0].status = "running"
        invalid.timers[0].completedAt = nil
        invalid.timers[0].deadline = Date()
        invalid.sessions[0].status = "active"
        invalid.sessions[0].currentStepIndex = 0
        XCTAssertThrowsError(try clean.preview(invalid))
        invalid.timers[0].status = "paused"
        invalid.timers[0].deadline = nil
        invalid.timers[0].remainingWhenPaused = 60
        XCTAssertThrowsError(try clean.preview(invalid))
        invalid = backup
        invalid.timers[0].status = "running"
        invalid.timers[0].stepID = recipe.steps[0].id
        invalid.timers[0].completedAt = nil
        invalid.timers[0].deadline = Date()
        XCTAssertThrowsError(try clean.preview(invalid)) // current step, ended session
        invalid = backup
        invalid.timers[0].recipeID = UUID()
        XCTAssertThrowsError(try clean.preview(invalid))
        invalid = backup
        let other = try sampleRecipe(title: "Other recipe")
        invalid.recipes.append(storedCopy(of: other))
        invalid.timers[0].recipeID = other.id
        XCTAssertThrowsError(try clean.preview(invalid))
        invalid = backup
        invalid.sessions[0].currentStepIndex = -1
        XCTAssertThrowsError(try clean.preview(invalid))
    }

    func testReplacementCancelsLiveTimerWhoseStepWasRemovedAndRoundTrips() throws {
        let (service, database, repository) = try makeService()
        let recipe = try sampleRecipe()
        let (session, timer) = try seedHistory(into: database, repository: repository, recipe: recipe)
        try database.write { db in
            try db.execute(sql: "UPDATE cook_sessions SET status = 'active', ended_at = NULL WHERE id = ?", arguments: [session.id.uuidString])
            try db.execute(sql: "UPDATE cook_timers SET status = 'running', completed_at = NULL, deadline = ? WHERE id = ?", arguments: [Date().addingTimeInterval(120), timer.id.uuidString])
        }
        var incoming = try service.exportDocument()
        incoming.recipes[0].steps = [incoming.recipes[0].steps[0]]
        incoming.sessions = []
        incoming.timers = []
        incoming.timerEvents = []
        _ = try service.apply(try service.preview(incoming))
        let backup = try service.exportDocument()
        XCTAssertEqual(backup.timers[0].status, "cancelled")
        XCTAssertEqual(backup.timers[0].stepName, timer.stepName)
        XCTAssertEqual(backup.sessions[0].currentStepIndex, 0)
        let (clean, _, _) = try makeService()
        _ = try clean.apply(try clean.preview(backup))
    }

    func testPreviewCancelAndStaleApplyAreMutationFree() throws {
        let (service, _, repository) = try makeService()
        try repository.create(sampleRecipe())
        var document = try service.exportDocument()
        document.recipes[0].title = "Incoming title"
        let before = try service.exportDocument()
        let preview = try service.preview(document)
        XCTAssertEqual(preview.outcome.recipesReplaced, 1)
        XCTAssertEqual(try service.exportDocument(), before) // cancel means discard preview
        try repository.create(sampleRecipe(title: "Changed meanwhile"))
        XCTAssertThrowsError(try service.apply(preview))
        XCTAssertEqual(try repository.fetchAll().first { $0.id == document.recipes[0].id }?.title, "Weeknight Chili")
    }

    func testArchiveRoundTripAndLegacyImportDoesNotResurrect() throws {
        let (service, _, repository) = try makeService()
        let recipe = try sampleRecipe()
        try repository.create(recipe)
        let legacy = try service.exportDocument()
        XCTAssertTrue(try repository.delete(id: recipe.id))
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertEqual(try repository.fetchArchived(), [recipe])
        let archived = try service.exportDocument()
        XCTAssertNotNil(archived.recipes[0].deletedAt)
        _ = try service.applyValidated(legacy)
        XCTAssertNil(try repository.fetch(id: recipe.id))
        let (other, _, recovered) = try makeService()
        _ = try other.apply(try other.preview(archived))
        XCTAssertTrue(try recovered.fetchAll().isEmpty)
        XCTAssertEqual(try recovered.fetchArchived(), [recipe])
        try recovered.restore(id: recipe.id)
        XCTAssertEqual(try recovered.fetch(id: recipe.id), recipe)
        try recovered.delete(id: recipe.id)
        try recovered.purge(id: recipe.id)
        XCTAssertTrue(try recovered.fetchArchived().isEmpty)
    }

    func testInvalidDirectApplyAndPreviewRollBack() throws {
        let (service, _, repository) = try makeService()
        try repository.create(sampleRecipe())
        var document = try service.exportDocument()
        document.recipes[0].title = " "
        XCTAssertThrowsError(try service.preview(document))
        XCTAssertThrowsError(try service.applyValidated(document))
        XCTAssertEqual(try repository.fetchAll()[0].title, "Weeknight Chili")
    }

    func testOnlyExplicitSaveConfirmationPersistsAcrossServiceInstances() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, database, repository) = try makeService(now: date)
        try repository.create(sampleRecipe())
        _ = try service.exportDocument() // preparing/canceling never confirms a save
        XCTAssertNil(try service.lastConfirmedBackup())
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: reportURL) }
        try service.writeHistoryCSV(to: reportURL)
        XCTAssertNil(try service.lastConfirmedBackup())
        try service.confirmBackupSaved()
        let reopened = DataTransferService(database: database)
        XCTAssertEqual(try reopened.lastConfirmedBackup(), date)
    }

    func testInterruptedApplyRollsBackAndPreviewRejectsDatabaseFailures() throws {
        let (service, database, repository) = try makeService()
        let first = try sampleRecipe(title: "First")
        let second = try sampleRecipe(title: "Second")
        var document = try service.exportDocument()
        document.recipes = [storedCopy(of: first), storedCopy(of: second)]
        let failure = ImportFailureSwitch()
        try database.write { db in
            db.add(function: DatabaseFunction("should_abort_import", argumentCount: 0) { _ in failure.enabled ? 1 : 0 })
            try db.execute(sql: "CREATE TRIGGER simulated_interruption BEFORE INSERT ON recipes WHEN NEW.title = 'Second' AND should_abort_import() = 1 BEGIN SELECT RAISE(ABORT, 'interrupted'); END")
        }
        let preview = try service.preview(document)
        XCTAssertEqual(preview.outcome.recipesAdded, 2)
        failure.enabled = true // External interruption, without a database change after preview.
        XCTAssertThrowsError(try service.apply(preview)) { error in
            XCTAssertNotEqual(error as? DataTransferError, .stalePreview)
        }
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertThrowsError(try service.preview(document))
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertThrowsError(try service.applyValidated(document))
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testValidatedBytesStayBoundToPreview() throws {
        let (service, _, repository) = try makeService()
        let source = try sampleRecipe()
        var document = try service.exportDocument()
        document.recipes = [storedCopy(of: source)]
        let url = try writeFile(String(decoding: service.encodedData(for: document), as: UTF8.self))
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try service.preview(service.validateDocument(at: url))
        XCTAssertEqual(preview.outcome.recipesAdded, 1)
        try Data("malformed replacement".utf8).write(to: url)
        _ = try service.apply(preview)
        XCTAssertEqual(try repository.fetch(id: source.id), source)
    }

    func testArchiveStopsSessionAndTimersAndBlocksCookingAndKeepsHistory() throws {
        let (service, database, repository) = try makeService()
        let recipe = try sampleRecipe()
        try repository.create(recipe)
        let session = try repository.beginCook(for: recipe.id)
        let timer = CookTimer(
            id: UUID(), recipeID: recipe.id, stepID: recipe.steps[1].id, cookSessionID: session.id,
            stepName: "Simmer", originalDuration: 300, status: .running,
            startedAt: Date(), deadline: Date().addingTimeInterval(300),
            remainingWhenPaused: nil, completedAt: nil, scheduleGeneration: 0
        )
        try TimerRepository(database: database).insertStarted(timer)
        try repository.delete(id: recipe.id)
        XCTAssertThrowsError(try repository.beginCook(for: recipe.id))
        XCTAssertThrowsError(try GroceryRepository(database: database).addSelection(recipeID: recipe.id, servings: 1))
        XCTAssertEqual(try repository.fetchCookSession(id: session.id)?.status, .abandoned)
        XCTAssertEqual(try TimerRepository(database: database).fetchTimers().first?.status, .cancelled)
        var document = try service.exportDocument()
        document = try service.decodedDocument(from: service.encodedData(for: document))
        let (other, _, recovered) = try makeService()
        _ = try other.apply(try other.preview(document))
        XCTAssertEqual(try recovered.fetchArchived(), [recipe])
        XCTAssertEqual(try recovered.fetchCookSession(id: session.id)?.status, .abandoned)
        XCTAssertEqual(try other.exportDocument().timers.first?.status, "cancelled")
    }

    func testLegacyGroceryImportDoesNotReAddDeletedRecipeAndPreviewMatchesApply() throws {
        let (service, database, repository) = try makeService()
        let recipe = try sampleRecipe()
        try repository.create(recipe)
        _ = try GroceryRepository(database: database).addSelection(recipeID: recipe.id, servings: 2)
        let legacy = try service.exportDocument()
        try repository.delete(id: recipe.id)
        let preview = try service.preview(legacy)
        XCTAssertEqual(preview.outcome.recipesArchived, 1)
        XCTAssertEqual(preview.outcome.grocerySelectionsAdded, 0)
        XCTAssertEqual(preview.outcome.grocerySelectionsExcluded, 1)
        XCTAssertTrue(try GroceryRepository(database: database).fetchSelections().isEmpty)
        XCTAssertEqual(try service.apply(preview), preview.outcome)
        XCTAssertTrue(try GroceryRepository(database: database).fetchSelections().isEmpty)
        XCTAssertNil(try repository.fetch(id: recipe.id))
        try repository.restore(id: recipe.id)
        XCTAssertTrue(try GroceryRepository(database: database).fetchSelections().isEmpty)
    }

    func testPreviewRefusesApplyEvenIfInterveningWriteRestoresOriginalContent() throws {
        let (service, database, repository) = try makeService()
        let recipe = try sampleRecipe()
        try repository.create(recipe)
        let preview = try service.preview(service.exportDocument())
        try database.write { db in
            try db.execute(sql: "UPDATE recipes SET title = 'Temporary' WHERE id = ?", arguments: [recipe.id.uuidString])
            try db.execute(sql: "UPDATE recipes SET title = ? WHERE id = ?", arguments: [recipe.title, recipe.id.uuidString])
        }
        XCTAssertThrowsError(try service.apply(preview)) { error in
            XCTAssertEqual(error as? DataTransferError, .stalePreview)
        }
        XCTAssertEqual(try repository.fetch(id: recipe.id), recipe)
    }

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

    func testScalingGuidanceRoundTripsThroughBackupJSON() throws {
        let (sourceService, _, sourceRepository) = try makeService()
        let recipe = try Recipe(
            title: "Guided Cake",
            servings: 8,
            ingredients: [try Ingredient(name: "Flour", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Bake.")],
            panSizeGuidance: "Use two 8-inch pans.",
            batchSizeGuidance: "Mix in two batches.",
            cookingTimeGuidance: "Check at 25 minutes."
        )
        try sourceRepository.create(recipe)

        let document = try sourceService.exportDocument()
        let data = try sourceService.encodedData(for: document)
        let decoded = try sourceService.decodedDocument(from: data)
        let (targetService, _, targetRepository) = try makeService()
        _ = try targetService.applyValidated(decoded)

        XCTAssertEqual(try targetRepository.fetch(id: recipe.id), recipe)
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

/// Accessed synchronously across DatabaseQueue.write calls in one test.
private final class ImportFailureSwitch: @unchecked Sendable {
    var enabled = false
}


private final class ImportNotificationScheduler: TimerNotificationScheduling, @unchecked Sendable {
    var authorization: NotificationAuthorization { .allowed }
    var scheduled: [TimerNotification] = []
    var removed: [UUID] = []

    func schedule(_ notification: TimerNotification,
                  completion: @escaping @Sendable (TimerNotificationScheduleResult) -> Void) {
        scheduled.append(notification)
        completion(.success)
    }

    func removePending(timerID: UUID) {
        scheduled.removeAll { $0.timerID == timerID }
    }

    func removeAll(timerID: UUID) {
        removed.append(timerID)
        scheduled.removeAll { $0.timerID == timerID }
    }
}
