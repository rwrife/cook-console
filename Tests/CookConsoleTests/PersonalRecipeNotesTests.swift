import Foundation
import GRDB
import XCTest
@testable import CookConsole

final class PersonalRecipeNotesTests: XCTestCase {
    private func recipe(id: UUID = UUID(), instruction: String = "Cook rice.") throws -> Recipe {
        try Recipe(id: id, title: "Starter Rice", servings: 2,
                   ingredients: [Ingredient(name: "Rice", amount: 1, unit: .cup)],
                   steps: [RecipeStep(instruction: instruction)])
    }

    func testDefaultAndRatingValidation() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let value = try recipe(); try repository.create(value)
        XCTAssertEqual(try repository.personalNotes(for: value.id), try PersonalRecipeNotes(recipeID: value.id))
        for rating in [0, -1, 6] {
            XCTAssertThrowsError(try PersonalRecipeNotes(recipeID: value.id, rating: rating))
        }
        XCTAssertThrowsError(try PersonalRecipeNotes(recipeID: value.id, notes: String(repeating: "x", count: 20_001)))
        XCTAssertThrowsError(try repository.savePersonalNotes(PersonalRecipeNotes(recipeID: UUID(), notes: "Missing")))
    }

    func testDecodedInvalidNotesCannotCorruptRepository() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let value = try recipe(); try repository.create(value)
        let valid = try PersonalRecipeNotes(recipeID: value.id, notes: "Keep me", rating: 2)
        try repository.savePersonalNotes(valid)
        for (notes, rating) in [(String(repeating: "x", count: 20_001), 2), ("Bad rating", 6)] {
            let data = try JSONSerialization.data(withJSONObject: ["recipeID": value.id.uuidString, "notes": notes, "rating": rating])
            let decoded = try JSONDecoder().decode(PersonalRecipeNotes.self, from: data)
            XCTAssertThrowsError(try repository.savePersonalNotes(decoded))
            XCTAssertEqual(try repository.personalNotes(for: value.id), valid)
        }
    }

    func testPersistenceAcrossDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recipes.sqlite").path
        let value = try recipe()
        let notes = try PersonalRecipeNotes(recipeID: value.id, notes: "Use oat milk.\nLess salt next time.", rating: 4)
        do {
            let repository = RecipeRepository(database: try RecipeDatabase.make(at: path))
            try repository.create(value); try repository.savePersonalNotes(notes)
        }
        let reopened = RecipeRepository(database: try RecipeDatabase.make(at: path))
        XCTAssertEqual(try reopened.personalNotes(for: value.id), notes)
    }

    func testContentUpdateArchiveRestoreAndPurge() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let starter = try recipe(); try repository.create(starter)
        let notes = try PersonalRecipeNotes(recipeID: starter.id, notes: "Less salt next time", rating: 5)
        try repository.savePersonalNotes(notes)
        // Cookbook/editor content replacement uses update, never note writes.
        try repository.update(recipe(id: starter.id, instruction: "Steam rice."))
        XCTAssertEqual(try repository.personalNotes(for: starter.id), notes)
        XCTAssertEqual(try repository.fetch(id: starter.id)?.steps.first?.instruction, "Steam rice.")
        try repository.delete(id: starter.id)
        XCTAssertEqual(try repository.personalNotes(for: starter.id), notes)
        XCTAssertThrowsError(try repository.savePersonalNotes(notes))
        try repository.restore(id: starter.id)
        XCTAssertEqual(try repository.personalNotes(for: starter.id), notes)
        try repository.savePersonalNotes(PersonalRecipeNotes(recipeID: starter.id))
        XCTAssertEqual(try repository.personalNotes(for: starter.id).notes, "")
        XCTAssertNil(try repository.personalNotes(for: starter.id).rating)
        try repository.savePersonalNotes(notes)
        try repository.delete(id: starter.id); try repository.purge(id: starter.id)
        let count = try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM personal_recipe_notes") }
        XCTAssertEqual(count, 0)
    }

    func testBackupRoundTripIncludingArchivedNotesAndLegacyImport() throws {
        let source = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let value = try recipe(); try source.create(value)
        let notes = try PersonalRecipeNotes(recipeID: value.id, notes: "Substitute herbs", rating: 3)
        try source.savePersonalNotes(notes)
        let service = DataTransferService(database: source.database)
        let backup = try service.exportDocument()
        let decoded = try service.decodedDocument(from: service.encodedData(for: backup))
        try DataTransferService.validateSemantics(of: decoded)
        let destination = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let importer = DataTransferService(database: destination.database)
        let outcome = try importer.applyValidated(decoded)
        XCTAssertEqual(outcome.personalNotesImported, 1)
        XCTAssertEqual(try destination.personalNotes(for: value.id), notes)
        var legacy = decoded
        legacy.personalNotes = nil
        legacy.recipes[0].steps[0].instruction = "Updated starter instructions."
        try importer.applyValidated(legacy)
        XCTAssertEqual(try destination.personalNotes(for: value.id), notes)
        // Explicit incoming cleared record replaces the local record.
        var cleared = decoded
        cleared.personalNotes = [try PersonalRecipeNotes(recipeID: value.id)]
        let preview = try importer.preview(cleared)
        XCTAssertEqual(preview.outcome.personalNotesImported, 1)
        XCTAssertEqual(try destination.personalNotes(for: value.id), notes, "Preview must not change notes")
        _ = try importer.apply(preview)
        XCTAssertNil(try destination.personalNotes(for: value.id).rating)
        try source.delete(id: value.id)
        let archived = try service.exportDocument()
        try importer.applyValidated(archived)
        XCTAssertEqual(try destination.personalNotes(for: value.id), notes)
        XCTAssertEqual(try destination.fetchArchived().map(\.id), [value.id])
    }

    func testMalformedBackupNotesRejectWholeFile() throws {
        let source = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let value = try recipe(); try source.create(value)
        let service = DataTransferService(database: source.database)
        var document = try service.exportDocument()
        let note = try PersonalRecipeNotes(recipeID: value.id, notes: "Valid", rating: 4)
        document.personalNotes = [note, note]
        XCTAssertThrowsError(try service.applyValidated(document))
        document.personalNotes = [try PersonalRecipeNotes(recipeID: UUID())]
        XCTAssertThrowsError(try service.applyValidated(document))
        document.personalNotes = [note]
        let encoded = try service.encodedData(for: document)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["personalNotes"] = [["recipeID": value.id.uuidString, "notes": "invalid", "rating": 6]]
        let invalid = try service.decodedDocument(from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try service.applyValidated(invalid))
        XCTAssertThrowsError(try DataTransferService.validateSemantics(of: invalid))
        json.removeValue(forKey: "personalNotes")
        let legacy = try service.decodedDocument(from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.personalNotes)
        XCTAssertEqual(try source.personalNotes(for: value.id).notes, "")
    }

    func testLastCookedUsesCompletedEndDateNotActiveAbandonedOrStart() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let value = try recipe(); try repository.create(value)
        XCTAssertNil(RecipeCookingSummary(sessions: try repository.fetchCookSessions(for: value.id)).lastCookedAt)
        let first = try repository.beginCook(for: value.id, at: Date(timeIntervalSince1970: 100))
        try repository.endCook(sessionID: first.id, as: .completed, at: Date(timeIntervalSince1970: 200))
        let second = try repository.beginCook(for: value.id, at: Date(timeIntervalSince1970: 50))
        try repository.endCook(sessionID: second.id, as: .completed, at: Date(timeIntervalSince1970: 300))
        let abandoned = try repository.beginCook(for: value.id, at: Date(timeIntervalSince1970: 400))
        try repository.endCook(sessionID: abandoned.id, as: .abandoned, at: Date(timeIntervalSince1970: 500))
        _ = try repository.beginCook(for: value.id, at: Date(timeIntervalSince1970: 600))
        let summary = RecipeCookingSummary(sessions: try repository.fetchCookSessions(for: value.id))
        XCTAssertEqual(summary.lastCookedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(summary.completedSessions.map(\.id), [second.id, first.id])
        let backup = try DataTransferService(database: repository.database).exportDocument()
        let imported = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        try DataTransferService(database: imported.database).applyValidated(backup)
        XCTAssertEqual(RecipeCookingSummary(sessions: try imported.fetchCookSessions(for: value.id)), summary)
    }
}
