import GRDB
import XCTest

@testable import CookConsole

/// Issue #20 offline-persistence coverage: the grocery tables against the
/// real GRDB store (in-memory), plus the backup round-trip that makes the
/// grocery state user-owned data like everything else.
final class GroceryRepositoryTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        try RecipeDatabase.makeInMemory()
    }

    private func recipe(_ title: String, servings: Double = 2) throws -> Recipe {
        try Recipe(
            title: title,
            servings: servings,
            ingredients: [try Ingredient(name: "Flour", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Mix.")]
        )
    }

    func testSelectionsAndManualItemsPersistAcrossReopenInInsertionOrder() throws {
        let database = try makeDatabase()
        let repository = GroceryRepository(database: database)
        let a = try recipe("A")
        let b = try recipe("B")
        let repoA = RecipeRepository(database: database)
        try repoA.create(a)
        try repoA.create(b)

        let first = try repository.addSelection(recipeID: b.id, servings: 4)
        let second = try repository.addSelection(recipeID: a.id, servings: 2)
        let item = try repository.addManualItem(name: "  Napkins  ")

        XCTAssertEqual(try repository.fetchSelections().map(\.id), [first.id, second.id])
        XCTAssertEqual(try repository.fetchManualItems().map(\.name), ["Napkins"])

        // Check flags round-trip (per ingredient key).
        try repository.setChecked(selectionID: first.id, ingredientKey: "flour", isChecked: true)
        try repository.setManualItemChecked(id: item.id, isChecked: true)
        XCTAssertEqual(try repository.fetchSelections().first?.checkedKeys, ["flour"])
        XCTAssertFalse(try repository.fetchSelections()[1].checkedKeys.contains("flour"))
        XCTAssertEqual(try repository.fetchManualItems().first?.isChecked, true)
    }

    func testAddingARecipeTwiceReturnsTheExistingSelection() throws {
        let database = try makeDatabase()
        let repository = GroceryRepository(database: database)
        let a = try recipe("Only once")
        try RecipeRepository(database: database).create(a)

        let first = try repository.addSelection(recipeID: a.id, servings: 2)
        let again = try repository.addSelection(recipeID: a.id, servings: 6)
        XCTAssertEqual(first.id, again.id)
        // The original servings survive — re-adding is a no-op, not an edit.
        XCTAssertEqual(again.servings, 2, accuracy: 0.0000001)
        XCTAssertEqual(try repository.fetchSelections().count, 1)
    }

    func testDeletingARecipeCascadesItsSelections() throws {
        let database = try makeDatabase()
        let recipeRepo = RecipeRepository(database: database)
        let repository = GroceryRepository(database: database)
        let a = try recipe("Gone soon")
        try recipeRepo.create(a)
        _ = try repository.addSelection(recipeID: a.id, servings: 2)
        XCTAssertEqual(try repository.fetchSelections().count, 1)

        XCTAssertTrue(try recipeRepo.delete(id: a.id))
        XCTAssertEqual(try repository.fetchSelections().count, 0)
    }

    func testServingBoundsAndNameBlanknessAreRejected() throws {
        let database = try makeDatabase()
        let repository = GroceryRepository(database: database)
        let a = try recipe("Bounded")
        try RecipeRepository(database: database).create(a)

        XCTAssertThrowsError(try repository.addSelection(recipeID: a.id, servings: 0))
        XCTAssertThrowsError(try repository.addSelection(recipeID: a.id, servings: .nan))
        XCTAssertThrowsError(try repository.updateServings(selectionID: UUID(), servings: -1))
        XCTAssertThrowsError(try repository.addManualItem(name: "   "))
    }

    func testDoneShoppingDeletesCheckedManualItemsAndUnchecksTheRest() throws {
        let database = try makeDatabase()
        let repository = GroceryRepository(database: database)
        let kept = try repository.addManualItem(name: "Keep")
        let bought = try repository.addManualItem(name: "Bought")
        try repository.setManualItemChecked(id: bought.id, isChecked: true)

        try repository.removeCheckedManualItems()
        try repository.uncheckAllManualItems()
        let remaining = try repository.fetchManualItems()
        XCTAssertEqual(remaining.map(\.name), ["Keep"])
        XCTAssertEqual(remaining.first?.id, kept.id)
        XCTAssertEqual(remaining.first?.isChecked, false)
    }

    // MARK: - Backup round-trip (issue #6 machinery, #20 payload)

    func testGroceryStateSurvivesJSONBackupExportImportRoundTrip() throws {
        let sourceDB = try makeDatabase()
        let recipeRepo = RecipeRepository(database: sourceDB)
        let grocery = GroceryRepository(database: sourceDB)
        let a = try recipe("Backup recipe")
        try recipeRepo.create(a)
        let selection = try grocery.addSelection(recipeID: a.id, servings: 3)
        try grocery.setChecked(selectionID: selection.id, ingredientKey: "flour", isChecked: true)
        _ = try grocery.addManualItem(name: "Dish soap")

        let service = DataTransferService(database: sourceDB, appVersion: "test", now: { Date(timeIntervalSince1970: 1) })
        let document = try service.exportDocument()
        XCTAssertEqual(document.grocerySelections?.count, 1)
        XCTAssertEqual(document.groceryManualItems?.count, 1)

        // A fresh store receives the backup.
        let targetDB = try makeDatabase()
        try RecipeRepository(database: targetDB).create(a)
        let targetService = DataTransferService(database: targetDB, appVersion: "test", now: { Date(timeIntervalSince1970: 2) })
        let outcome = try targetService.applyValidated(document)
        XCTAssertEqual(outcome.recipesSkipped, 1)
        XCTAssertEqual(outcome.grocerySelectionsAdded, 1)
        XCTAssertEqual(outcome.groceryManualItemsAdded, 1)

        let restored = GroceryRepository(database: targetDB)
        let restoredSelections = try restored.fetchSelections()
        XCTAssertEqual(restoredSelections.map(\.id), [selection.id])
        XCTAssertEqual(restoredSelections.first?.servings, 3)
        XCTAssertEqual(restoredSelections.first?.checkedKeys, ["flour"])
        XCTAssertEqual(try restored.fetchManualItems().map(\.name), ["Dish soap"])

        // Re-importing the same file is idempotent (stable-ID skip).
        let again = try targetService.applyValidated(document)
        XCTAssertEqual(again.grocerySelectionsSkipped, 1)
        XCTAssertEqual(again.groceryManualItemsSkipped, 1)
        XCTAssertEqual(try restored.fetchSelections().count, 1)
    }

    func testSelectionReferencingUnknownRecipeFailsValidationWithoutWrites() throws {
        let sourceDB = try makeDatabase()
        let service = DataTransferService(database: sourceDB, appVersion: "test", now: { Date() })
        var document = try service.exportDocument()
        document.grocerySelections = [
            BackupDocument.StoredGrocerySelection(
                id: UUID(), recipeID: UUID(), servings: 2, checkedKeys: [], position: 0
            ),
        ]
        XCTAssertThrowsError(try DataTransferService.validateSemantics(of: document))
    }

    func testLegacyBackupFileWithoutGroceryFieldsStillDecodesAndImports() throws {
        // Schema 1 predates the grocery list; its files have no grocery keys.
        // The optional-additive contract means they must still decode.
        let legacyJSON = """
        {
          "header": {
            "schemaVersion": 1,
            "exportedAt": "2026-09-01T00:00:00.000+00:00",
            "appVersion": "0.9 (build 1)"
          },
          "recipes": [],
          "sessions": [],
          "timers": [],
          "timerEvents": []
        }
        """
        let service = DataTransferService(database: try makeDatabase(), appVersion: "test", now: { Date() })
        let document = try service.decodedDocument(from: Data(legacyJSON.utf8))
        XCTAssertNil(document.grocerySelections)
        XCTAssertNil(document.groceryManualItems)
        let outcome = try service.applyValidated(document)
        XCTAssertEqual(outcome.recipesAdded, 0)
    }
}
