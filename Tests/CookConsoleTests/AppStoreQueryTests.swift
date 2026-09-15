#if canImport(SwiftUI)
import XCTest

@testable import CookConsole

@MainActor
final class AppStoreQueryTests: XCTestCase {
    func testSaveAndEndCookReloadUsingActiveComposedQuery() throws {
        let repository = RecipeRepository(database: try RecipeDatabase.makeInMemory())
        let matching = try Recipe(
            title: "Quick Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer.")],
            tags: ["QUICK"]
        )
        let titleOnly = try Recipe(
            title: "Slow Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer.")],
            tags: ["weekend"]
        )
        let tagOnly = try Recipe(
            title: "Quick Toast",
            servings: 2,
            ingredients: [try Ingredient(name: "Bread", amount: 1, unit: .each)],
            steps: [try RecipeStep(instruction: "Toast.")],
            tags: ["quick"]
        )
        try repository.create(matching)
        try repository.create(titleOnly)
        try repository.create(tagOnly)
        let store = AppStore(repository: repository)
        store.loadLibrary(searchText: "Soup", selectedTag: "QUICK")
        XCTAssertEqual(store.allTags.filter { $0.lowercased() == "quick" }.count, 1)

        try store.save(matching, isNew: false)
        XCTAssertEqual(store.recipes.map(\.id), [matching.id])

        let session = try store.beginCook(for: matching.id)
        try store.endCook(sessionID: session.id, as: .completed)
        XCTAssertEqual(store.recipes.map(\.id), [matching.id])
    }
}
#endif
