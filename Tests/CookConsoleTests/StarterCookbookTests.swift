import Foundation
import GRDB
import XCTest

@testable import CookConsole

final class StarterCookbookTests: XCTestCase {
    func testBackupPreservesStarterVersionDecisionsOnRestore() throws {
        let database = try RecipeDatabase.makeInMemory()
        try database.write { db in
            try db.execute(sql: "INSERT INTO app_metadata (key, value) VALUES ('starter.cookbook.skipped', '1')")
        }
        let source = DataTransferService(database: database)
        let document = try source.exportDocument()
        let restored = try RecipeDatabase.makeInMemory()
        let destination = DataTransferService(database: restored)
        _ = try destination.applyValidated(document)
        let skipped = try restored.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'starter.cookbook.skipped'")
        }
        XCTAssertEqual(skipped, "1", "Restoring must retain starter version decisions, avoiding repeated offers or accidental adoption.")
    }

    private func fixture(version: Int = 1, title: String = "Starter Rice") throws -> StarterCookbookPack {
        let id = UUID(uuidString: "25000000-0000-0000-0000-000000000099")!
        let recipe = try Recipe(id: id, title: title, servings: 2,
            ingredients: [Ingredient(id: UUID(uuidString: "25000000-0000-0000-0001-000000000099")!, name: "Rice", amount: 1, unit: .cup)],
            steps: [RecipeStep(id: UUID(uuidString: "25000000-0000-0000-0002-000000000099")!, instruction: "Simmer rice until tender.", timerDuration: 600)])
        return StarterCookbookPack(version: version, recipes: [recipe])
    }

    func testReviewDoesNotInstallAndAcceptanceIsIdempotentAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recipes.sqlite").path
        let pack = try fixture()
        do {
            let repository = RecipeRepository(database: try RecipeDatabase.make(at: path))
            let service = StarterCookbookService(repository: repository)
            let review = try XCTUnwrap(service.review(pack))
            XCTAssertTrue(try repository.fetchAll().isEmpty)
            XCTAssertEqual(review.entries.map(\.action), [.add])
            try service.accept(review)
            try service.accept(review)
            XCTAssertEqual(try repository.fetchAll(), pack.recipes)
        }
        let reopened = RecipeRepository(database: try RecipeDatabase.make(at: path))
        XCTAssertNil(try StarterCookbookService(repository: reopened).review(pack))
        XCTAssertEqual(try reopened.fetchAll().count, 1)
    }

    func testSkippedVersionDoesNotSuppressLaterVersionOrInstallOnLaunch() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.skip(XCTUnwrap(service.review(v1)))
        XCTAssertNil(try StarterCookbookService(repository: repository).review(v1))
        let v3 = try fixture(version: 3, title: "New rice")
        let review = try XCTUnwrap(service.review(v3))
        XCTAssertEqual(review.entries.map(\.action), [.add])
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        try service.accept(review)
        XCTAssertEqual(try repository.fetchAll(), v3.recipes)
        XCTAssertNil(try service.review(try fixture(version: 2)))
    }

    func testUpdatesPreserveFavoritesNotesRatingsAndHistory() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let original = v1.recipes[0]
        try repository.database.write { db in
            try db.execute(sql: "UPDATE recipes SET is_favorite = 1 WHERE id = ?", arguments: [original.id.uuidString])
        }
        let notes = try PersonalRecipeNotes(recipeID: original.id, notes: "Less salt next time", rating: 4)
        try repository.savePersonalNotes(notes)
        let session = try repository.beginCook(for: original.id)
        try repository.endCook(sessionID: session.id, as: .completed)
        let history = try repository.fetchCookSessions(for: original.id)
        let v2 = try fixture(version: 2, title: "Improved Rice")
        let review = try XCTUnwrap(service.review(v2))
        XCTAssertEqual(review.entries.map(\.action), [.update])
        try service.accept(review)
        XCTAssertEqual(try repository.fetch(id: original.id)?.title, "Improved Rice")
        XCTAssertEqual(try repository.fetch(id: original.id)?.isFavorite, true)
        XCTAssertEqual(try repository.personalNotes(for: original.id), notes)
        XCTAssertEqual(try repository.fetchCookSessions(for: original.id), history)
    }

    func testEditedRecipesAndUUIDCollisionsAreExplicitlyKeptWithoutTitleMatching() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        let personal = try Recipe(title: v1.recipes[0].title, servings: 1,
            ingredients: [Ingredient(name: "My rice", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "My method.")])
        try repository.create(personal)
        try service.accept(XCTUnwrap(service.review(v1)))
        XCTAssertEqual(try repository.fetchAll().count, 2)
        let edited = try Recipe(id: v1.recipes[0].id, title: "My edited starter", servings: 3,
            ingredients: personal.ingredients, steps: personal.steps)
        // Use distinct children from the unrelated personal recipe.
        let editedCopy = try Recipe(id: edited.id, title: edited.title, servings: edited.servings,
            ingredients: [Ingredient(name: "Brown rice", amount: 2, unit: .cup)],
            steps: [RecipeStep(instruction: "Cook my way.")])
        try repository.update(editedCopy)
        let review = try XCTUnwrap(service.review(try fixture(version: 2, title: "Updated Rice")))
        XCTAssertEqual(review.entries.map(\.action), [.keepEdited])
        try service.accept(review)
        XCTAssertEqual(try repository.fetch(id: edited.id), editedCopy)
        XCTAssertEqual(try repository.fetch(id: personal.id), personal)

        let other = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        try other.create(v1.recipes[0]) // UUID collision alone does not establish provenance.
        let collisionService = StarterCookbookService(repository: other)
        let collision = try XCTUnwrap(collisionService.review(v1))
        XCTAssertEqual(collision.entries.map(\.action), [.keepUntracked])
        try collisionService.accept(collision)
        XCTAssertEqual(try other.fetchAll(), v1.recipes)
    }

    func testArchivedAndPurgedTombstonesNeverReappear() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let id = v1.recipes[0].id
        try repository.delete(id: id)
        let review = try XCTUnwrap(service.review(try fixture(version: 2, title: "Updated rice")))
        XCTAssertEqual(review.entries.map(\.action), [.keepArchived])
        try service.accept(review)
        XCTAssertEqual(try repository.fetchArchived(), v1.recipes)
        try repository.purge(id: id)
        let afterPurge = try XCTUnwrap(service.review(try fixture(version: 3)))
        XCTAssertEqual(afterPurge.entries.map(\.action), [.keepArchived])
        try service.accept(afterPurge)
        XCTAssertTrue(try repository.fetchAll().isEmpty)
    }

    func testActiveCookAndLiveTimerBlockDestructiveUpdatesAndStaleReview() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let v2 = try fixture(version: 2, title: "Updated rice")
        let beforeCook = try XCTUnwrap(service.review(v2))
        let recipe = v1.recipes[0]
        let session = try repository.beginCook(for: recipe.id)
        XCTAssertThrowsError(try service.accept(beforeCook))
        let review = try XCTUnwrap(service.review(v2))
        XCTAssertEqual(review.entries.map(\.action), [.blockedActiveCook])
        XCTAssertThrowsError(try service.accept(review))
        let timer = CookTimer(id: UUID(), recipeID: recipe.id, stepID: recipe.steps[0].id,
            cookSessionID: session.id, stepName: recipe.steps[0].instruction, originalDuration: 600,
            status: .running, startedAt: Date(timeIntervalSince1970: 1000), deadline: Date(timeIntervalSince1970: 1600),
            remainingWhenPaused: nil, completedAt: nil, scheduleGeneration: 0)
        let timers = TimerRepository(database: repository.database)
        try timers.insertStarted(timer)
        try repository.endCook(sessionID: session.id, as: .completed)
        let timerBlocked = try XCTUnwrap(service.review(v2))
        XCTAssertEqual(timerBlocked.entries.map(\.action), [.blockedActiveCook])
        XCTAssertThrowsError(try service.accept(timerBlocked))
        XCTAssertEqual(try timers.fetchTimer(id: timer.id), timer)
        XCTAssertEqual(try repository.fetch(id: recipe.id), recipe)
    }

    func testMidPackFailureRollsBackRecipesBaselinesAndAcceptedVersion() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let pack = try StarterCookbookPack.bundled()
        XCTAssertEqual(pack.recipes.count, 2)
        let review = try XCTUnwrap(service.review(pack))
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_starter BEFORE INSERT ON recipes WHEN NEW.id = '\(pack.recipes[1].id.uuidString)' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        XCTAssertThrowsError(try service.accept(review))
        XCTAssertTrue(try repository.fetchAll().isEmpty)
        XCTAssertEqual(try service.review(pack), review)
        try repository.database.write { db in try db.execute(sql: "DROP TRIGGER fail_starter") }
        try service.accept(review)
        XCTAssertEqual(try repository.fetchAll().count, 2)
        XCTAssertNil(try service.review(pack))
    }

    func testRestoredProvenanceSupportsFutureUpdatesAndLegacyImportPreservesIt() throws {
        let source = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: source)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let transfer = DataTransferService(database: source.database)
        let backup = try transfer.decodedDocument(from: transfer.encodedData(for: transfer.exportDocument()))
        let restored = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let importer = DataTransferService(database: restored.database)
        _ = try importer.applyValidated(backup)
        let restoredService = StarterCookbookService(repository: restored)
        XCTAssertNil(try restoredService.review(v1))
        let v2 = try fixture(version: 2, title: "Updated rice")
        XCTAssertEqual(try restoredService.review(v2)?.entries.map(\.action), [.update])
        var legacy = backup
        legacy.starterCookbookMetadata = nil
        _ = try importer.applyValidated(legacy)
        XCTAssertEqual(try restoredService.review(v2)?.entries.map(\.action), [.update])
        try restoredService.accept(XCTUnwrap(restoredService.review(v2)))
        XCTAssertEqual(try restored.fetch(id: v1.recipes[0].id)?.title, "Updated rice")
    }


    func testSkippedIntermediateVersionUsesLastAcceptedBaseline() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        try service.skip(XCTUnwrap(service.review(try fixture(version: 2, title: "Skipped rice"))))
        XCTAssertEqual(try repository.fetchAll(), v1.recipes)
        let v3 = try fixture(version: 3, title: "Latest rice")
        let review = try XCTUnwrap(service.review(v3))
        XCTAssertEqual(review.entries.map(\.action), [.update])
        try service.accept(review)
        XCTAssertEqual(try repository.fetchAll(), v3.recipes)
    }

    func testUpdateFailureRollsBackContentAndProvenanceTogether() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let replacement = try fixture(version: 2, title: "Updated rice").recipes[0]
        let extra = try StarterCookbookPack.bundled().recipes[0]
        let v2 = StarterCookbookPack(version: 2, recipes: [replacement, extra])
        let review = try XCTUnwrap(service.review(v2))
        let transfer = DataTransferService(database: repository.database)
        let before = try transfer.exportDocument()
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_second BEFORE INSERT ON recipes WHEN NEW.id = '\(extra.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        XCTAssertThrowsError(try service.accept(review))
        let after = try transfer.exportDocument()
        XCTAssertEqual(after.recipes, before.recipes)
        XCTAssertEqual(after.starterCookbookMetadata, before.starterCookbookMetadata)
        XCTAssertEqual(try service.review(v2), review)
        try repository.database.write { db in try db.execute(sql: "DROP TRIGGER fail_second") }
        try service.accept(review)
        XCTAssertEqual(try repository.fetch(id: replacement.id), replacement)
    }

    func testArchiveAndPurgeProvenanceSurvivesBackupWithoutResurrection() throws {
        let source = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: source)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        try source.delete(id: v1.recipes[0].id)
        for purge in [false, true] {
            if purge { try source.purge(id: v1.recipes[0].id) }
            let transfer = DataTransferService(database: source.database)
            let restored = RecipeRepository(database: try RecipeDatabase.makeInMemory())
            _ = try DataTransferService(database: restored.database).applyValidated(transfer.exportDocument())
            let updater = StarterCookbookService(repository: restored)
            let review = try XCTUnwrap(updater.review(try fixture(version: 2)))
            XCTAssertEqual(review.entries.map(\.action), [.keepArchived])
            try updater.accept(review)
            XCTAssertTrue(try restored.fetchAll().isEmpty)
            XCTAssertEqual(try restored.fetchArchived().count, purge ? 0 : 1)
        }
    }

    func testMalformedStarterMetadataRejectsBackupBeforeAnyMutation() throws {
        let source = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let recipe = try fixture().recipes[0]
        try source.create(recipe)
        var backup = try DataTransferService(database: source.database).exportDocument()
        let restored = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let importer = DataTransferService(database: restored.database)
        for metadata in [["last_confirmed_backup": "1"], ["starter.cookbook.skipped": "-1"],
                         ["starter.cookbook.baseline." + recipe.id.uuidString: "{}"]] {
            backup.starterCookbookMetadata = metadata
            XCTAssertThrowsError(try importer.applyValidated(backup))
            XCTAssertTrue(try restored.fetchAll().isEmpty)
        }
    }

    func testRemovedChildrenDoNotEraseCompletedTimerHistory() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let service = StarterCookbookService(repository: repository)
        let v1 = try fixture()
        try service.accept(XCTUnwrap(service.review(v1)))
        let recipe = v1.recipes[0]
        let session = try repository.beginCook(for: recipe.id, at: Date(timeIntervalSince1970: 1000))
        let timers = TimerRepository(database: repository.database)
        let timer = CookTimer(id: UUID(), recipeID: recipe.id, stepID: recipe.steps[0].id,
            cookSessionID: session.id, stepName: recipe.steps[0].instruction, originalDuration: 600,
            status: .running, startedAt: Date(timeIntervalSince1970: 1000), deadline: Date(timeIntervalSince1970: 1600),
            remainingWhenPaused: nil, completedAt: nil, scheduleGeneration: 0)
        try timers.insertStarted(timer)
        let ended = CookTimer(id: timer.id, recipeID: timer.recipeID, stepID: timer.stepID,
            cookSessionID: timer.cookSessionID, stepName: timer.stepName, originalDuration: 600,
            status: .completed, startedAt: timer.startedAt, deadline: nil, remainingWhenPaused: nil,
            completedAt: Date(timeIntervalSince1970: 1600), scheduleGeneration: 1)
        try timers.update(ended)
        try repository.endCook(sessionID: session.id, as: .completed, at: Date(timeIntervalSince1970: 1600))
        let sessions = try repository.fetchCookSessions(for: recipe.id)
        let events = try timers.fetchEvents(timerID: timer.id)
        let changed = try Recipe(id: recipe.id, title: "New rice", servings: 2,
            ingredients: [Ingredient(name: "Rice", amount: 2, unit: .cup)],
            steps: [RecipeStep(instruction: "Steam until tender.")])
        let v2 = StarterCookbookPack(version: 2, recipes: [changed])
        try service.accept(XCTUnwrap(service.review(v2)))
        XCTAssertEqual(try repository.fetch(id: recipe.id), changed)
        XCTAssertEqual(try repository.fetchCookSessions(for: recipe.id), sessions)
        XCTAssertEqual(try timers.fetchTimer(id: timer.id), ended)
        XCTAssertEqual(try timers.fetchEvents(timerID: timer.id), events)
    }
}
