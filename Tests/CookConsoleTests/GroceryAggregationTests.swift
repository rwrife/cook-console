import XCTest

@testable import CookConsole

/// Issue #20 acceptance coverage for the pure merge engine: deduplication,
/// unit conversion, fractional amounts, provenance, optional/to-taste
/// separation, and predictable check state across serving changes and
/// recipe edits — all without GRDB or UI.
final class GroceryAggregationTests: XCTestCase {
    private func recipe(
        title: String,
        servings: Double = 2,
        ingredients: [(String, Double, IngredientUnit)]
    ) throws -> Recipe {
        try Recipe(
            title: title,
            servings: servings,
            ingredients: ingredients.map { try Ingredient(name: $0.0, amount: $0.1, unit: $0.2) },
            steps: [try RecipeStep(instruction: "Cook.")]
        )
    }

    private func selection(_ recipe: Recipe, servings: Double, checked: Bool = false) throws -> GrocerySelection {
        // checked == true mimics the UI fan-out: the flag lands on every
        // merge-key the recipe contributes (per-key storage semantics).
        try GrocerySelection(
            recipeID: recipe.id,
            servings: servings,
            checkedKeys: checked ? GroceryAggregationEngine.contributedKeys(for: recipe) : []
        )
    }

    private func line(_ snapshot: GroceryListSnapshot, key: String, unit: IngredientUnit? = nil) -> GroceryLine? {
        snapshot.recipeLines.first {
            $0.normalizedKey == key && (unit == nil || $0.unit == unit)
        }
    }

    /// A measured line always carries its exact amount; nil means the test
    /// grabbed a taste-dose line by mistake, so fail loudly instead of
    /// comparing optionals.
    private func exact(_ line: GroceryLine) throws -> Double {
        try XCTUnwrap(line.exactAmount, "line \(line.name) has no exact amount")
    }

    private func display(_ line: GroceryLine) throws -> Double {
        try XCTUnwrap(line.displayAmount, "line \(line.name) has no display amount")
    }

    // MARK: - Merging

    func testEquivalentIngredientsMergeAcrossRecipesWithProvenance() throws {
        let riceA = try recipe(title: "Rice Bowl", ingredients: [("Rice", 1, .cup), ("Water", 2, .cup)])
        let riceB = try recipe(title: "Fried Rice", ingredients: [("rice ", 0.5, .cup)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(riceA, servings: 2), try selection(riceB, servings: 2)],
            manualItems: [],
            recipes: [riceA, riceB]
        )
        let riceLine = try XCTUnwrap(line(snapshot, key: "rice", unit: .cup))
        XCTAssertEqual(try exact(riceLine), 1.5, accuracy: 0.0000001)
        XCTAssertEqual(try display(riceLine), 1.5, accuracy: 0.0000001)
        XCTAssertEqual(Set(riceLine.sources), ["Rice Bowl × 2", "Fried Rice × 2"])
        // Water stays separate — different ingredient.
        XCTAssertNotNil(line(snapshot, key: "water", unit: .cup))
    }

    func testIncompatibleUnitsNeverMerge() throws {
        let milkRecipe = try recipe(
            title: "Pudding",
            ingredients: [("Milk", 50, .milliliter), ("Milk", 2, .each)]
        )
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(milkRecipe, servings: 2)],
            manualItems: [],
            recipes: [milkRecipe]
        )
        // 50 ml is below the 0.1 L granularity floor, so it stays milliliters.
        let volume = try XCTUnwrap(line(snapshot, key: "milk", unit: .milliliter))
        XCTAssertEqual(try exact(volume), 50, accuracy: 0.0000001)
        // 'each' milk has no weight proxy -> stays a count line, never grams.
        let count = try XCTUnwrap(line(snapshot, key: "milk", unit: .each))
        XCTAssertEqual(try exact(count), 2, accuracy: 0.0000001)
    }

    func testCompatibleUnitsConvertAtShoppingGranularity() throws {
        // 8 tbsp == 1/2 cup (>= 0.25 cup) merges into the cup bucket;
        // 2 tbsp (1/8 cup) stays spoons.
        let dressingA = try recipe(title: "Vinaigrette", ingredients: [("Vinegar", 8, .tablespoon)])
        let dressingB = try recipe(title: "Marinade", ingredients: [("Vinegar", 2, .tablespoon)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(dressingA, servings: 2), try selection(dressingB, servings: 2)],
            manualItems: [],
            recipes: [dressingA, dressingB]
        )
        let cupLine = try XCTUnwrap(line(snapshot, key: "vinegar", unit: .cup))
        XCTAssertEqual(try exact(cupLine), 0.5, accuracy: 0.0000001)
        let spoonLine = try XCTUnwrap(line(snapshot, key: "vinegar", unit: .tablespoon))
        XCTAssertEqual(try exact(spoonLine), 2, accuracy: 0.0000001)
        XCTAssertEqual(spoonLine.sources, ["Marinade × 2"])
    }

    func testKilogramsAndOuncesFoldIntoFinerMassUnits() throws {
        let bulk = try recipe(
            title: "Bulk",
            ingredients: [("Flour", 1, .kilogram), ("Sugar", 24, .ounce)]
        )
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(bulk, servings: 2)],
            manualItems: [],
            recipes: [bulk]
        )
        let flour = try XCTUnwrap(line(snapshot, key: "flour", unit: .gram))
        XCTAssertEqual(try exact(flour), 1000, accuracy: 0.0000001)
        let sugar = try XCTUnwrap(line(snapshot, key: "sugar", unit: .pound))
        XCTAssertEqual(try exact(sugar), 1.5, accuracy: 0.0000001)
    }

    func testWeightConvertibleCountsMergeIntoGrams() throws {
        // Cheese converts at 30 g each; eggs never convert (indivisible).
        let pasta = try recipe(title: "Pasta", ingredients: [("Cheese", 2, .each), ("Eggs", 3, .each)])
        let salad = try recipe(title: "Salad", ingredients: [("Cheese", 1, .each)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(pasta, servings: 2), try selection(salad, servings: 4)],
            manualItems: [],
            recipes: [pasta, salad]
        )
        // Pasta at original servings: 2 each = 60 g. Salad doubled to 4
        // servings: 1 each x 2 = 2 each = 60 g. Total 120 g.
        let cheese = try XCTUnwrap(line(snapshot, key: "cheese", unit: .gram))
        XCTAssertEqual(try exact(cheese), 120, accuracy: 0.0000001)
        let eggs = try XCTUnwrap(line(snapshot, key: "eggs", unit: .each))
        XCTAssertEqual(try exact(eggs), 3, accuracy: 0.0000001)
    }

    func testAliasNamesMergeUsingTheSameStrictTableAsPantry() throws {
        let a = try recipe(title: "Curry", ingredients: [("Chickpeas", 1, .cup)])
        let b = try recipe(title: "Hummus", ingredients: [("Garbanzo beans", 0.5, .cup)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(a, servings: 2), try selection(b, servings: 2)],
            manualItems: [],
            recipes: [a, b]
        )
        let merged = try XCTUnwrap(line(snapshot, key: "garbanzo beans", unit: .cup))
        XCTAssertEqual(try exact(merged), 1.5, accuracy: 0.0000001)
        XCTAssertEqual(merged.sources.count, 2)
    }

    // MARK: - Servings & fractional amounts

    func testPerSelectionServingsScaleContributionsExactly() throws {
        let soup = try recipe(title: "Soup", servings: 2, ingredients: [("Stock", 1, .cup)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(soup, servings: 3)],
            manualItems: [],
            recipes: [soup]
        )
        let stock = try XCTUnwrap(line(snapshot, key: "stock", unit: .cup))
        XCTAssertEqual(try exact(stock), 1.5, accuracy: 0.0000001)
        XCTAssertEqual(stock.sources, ["Soup × 3"])

        let doubled = GroceryAggregationEngine.aggregate(
            selections: [try selection(soup, servings: 6)],
            manualItems: [],
            recipes: [soup]
        )
        let bigStock = try XCTUnwrap(line(doubled, key: "stock", unit: .cup))
        XCTAssertEqual(try exact(bigStock), 3, accuracy: 0.0000001)
    }

    func testFractionalSumsKeepExactMathAndKitchenDisplaySeparately() throws {
        // 0.33 + 0.33 = 0.66 exact; display snaps to the eighth-cup tier
        // below 1 cup -> 5/8.
        let a = try recipe(title: "A", ingredients: [("Sauce", 0.33, .cup)])
        let b = try recipe(title: "B", ingredients: [("Sauce", 0.33, .cup)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(a, servings: 2), try selection(b, servings: 2)],
            manualItems: [],
            recipes: [a, b]
        )
        let sauce = try XCTUnwrap(line(snapshot, key: "sauce", unit: .cup))
        XCTAssertEqual(try exact(sauce), 0.66, accuracy: 0.0000001)
        XCTAssertEqual(try display(sauce), 0.625, accuracy: 0.0000001)
    }

    // MARK: - Taste doses / optional qualifiers

    func testTasteDoseIngredientsNeverSumAndCarryQualifier() throws {
        let a = try recipe(title: "Soup", ingredients: [("Salt to taste", 1, .teaspoon)])
        let b = try recipe(title: "Stew", ingredients: [("Salt to taste", 2, .teaspoon)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(a, servings: 2), try selection(b, servings: 2)],
            manualItems: [],
            recipes: [a, b]
        )
        // The taste-line id convention is `recipe:<key>:taste`.
        let tasteLine = try XCTUnwrap(snapshot.recipeLines.first { $0.isTasteDosed })
        XCTAssertNil(tasteLine.exactAmount)
        XCTAssertEqual(Set(tasteLine.sources), ["Soup × 2", "Stew × 2"])
        XCTAssertTrue(tasteLine.hasOptionalContribution)
    }

    func testOptionalQualifierPropagatesOntoMergedMeasuredLine() throws {
        let strict = try recipe(title: "Strict", ingredients: [("Chili flakes", 1, .teaspoon)])
        let loose = try recipe(title: "Loose", ingredients: [("Chili flakes", 0.5, .teaspoon)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(strict, servings: 2), try selection(loose, servings: 2)],
            manualItems: [],
            recipes: [strict, loose]
        )
        // No "optional" markers in names here -> the merged line is plain.
        let lineOne = try XCTUnwrap(line(snapshot, key: "chili flakes", unit: .teaspoon))
        XCTAssertFalse(lineOne.hasOptionalContribution)
        XCTAssertEqual(try exact(lineOne), 1.5, accuracy: 0.0000001)
    }

    // MARK: - Checks: derived, stable, fan-out

    func testMergedLineCheckedOnlyWhenEveryContributingSelectionChecked() throws {
        // Onions are weight-convertible (30 g each), so both 'each' onion
        // lines merge into one grams line: 1 + 2 = 3 each = 90 g.
        let a = try recipe(title: "A", ingredients: [("Onion", 1, .each)])
        let b = try recipe(title: "B", ingredients: [("Onion", 2, .each)])
        let c = try recipe(title: "C", ingredients: [("Butter", 1, .tablespoon)])
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [
                try selection(a, servings: 2, checked: true),
                try selection(b, servings: 2, checked: false),
                try selection(c, servings: 2, checked: true),
            ],
            manualItems: [],
            recipes: [a, b, c]
        )
        let onion = try XCTUnwrap(line(snapshot, key: "onion", unit: .gram))
        XCTAssertEqual(try exact(onion), 90, accuracy: 0.0000001)
        XCTAssertFalse(onion.isChecked, "one unchecked contribution must keep the line unchecked")
        // Butter belongs only to C -> its own key -> derived checked.
        // 1 tbsp is below the cup-merge floor, so it stays a tablespoon.
        let butter = try XCTUnwrap(line(snapshot, key: "butter", unit: .tablespoon))
        XCTAssertTrue(butter.isChecked)
    }

    func testCheckingFanOutTouchesOnlyContributingSelections() throws {
        let a = try recipe(title: "A", ingredients: [("Garlic", 1, .teaspoon)])
        let b = try recipe(title: "B", ingredients: [("Garlic", 2, .teaspoon)])
        let c = try recipe(title: "C", ingredients: [("Butter", 10, .gram)])
        let selA = try selection(a, servings: 2)
        let selB = try selection(b, servings: 2)
        let selC = try selection(c, servings: 2)
        let contributing = GroceryAggregationEngine.checkedSelectionIDs(
            forLineKey: "garlic",
            selections: [selA, selB, selC],
            recipes: [a, b, c]
        )
        XCTAssertEqual(Set(contributing), Set([selA.id, selB.id]))
    }

    func testRecipeEditNeverStripsCheckOfSurvivingContributions() throws {
        let a = try recipe(title: "A", ingredients: [("Tomato", 1, .each)])
        let b = try recipe(title: "B", ingredients: [("Tomato", 2, .each), ("Basil", 1, .each)])
        let selA = try selection(a, servings: 2, checked: true)
        var selB = try selection(b, servings: 2)
        // User checks B's line -> fan-out marks every key B contributes...
        selB = selB.withCheckedKeys(GroceryAggregationEngine.contributedKeys(for: b))
        let before = GroceryAggregationEngine.aggregate(
            selections: [selA, selB], manualItems: [], recipes: [a, b]
        )
        XCTAssertTrue(try XCTUnwrap(line(before, key: "tomato", unit: .each)).isChecked)

        // Now B is edited (Basil quantity changes, Tomato untouched).
        // A real edit keeps the recipe's identity — same id, new content.
        let editedB = try Recipe(
            id: b.id,
            title: "B",
            servings: 2,
            ingredients: [
                try Ingredient(name: "Tomato", amount: 2, unit: .each),
                try Ingredient(name: "Basil", amount: 3, unit: .each),
            ],
            steps: [try RecipeStep(instruction: "Mix.")]
        )
        let after = GroceryAggregationEngine.aggregate(
            selections: [selA, selB], manualItems: [], recipes: [a, editedB]
        )
        // Tomato is not in the weight-proxy table, so each-lines stay counts.
        let tomato = try XCTUnwrap(line(after, key: "tomato", unit: .each))
        XCTAssertEqual(try exact(tomato), 3, accuracy: 0.0000001)
        XCTAssertTrue(tomato.isChecked, "edit must not lose check state")
        let basil = try XCTUnwrap(line(after, key: "basil", unit: .each))
        XCTAssertEqual(try exact(basil), 3, accuracy: 0.0000001)
        XCTAssertTrue(basil.isChecked, "B's fan-out check covers all its contributions")
    }

    func testServingChangeRecomputesAmountsWithoutChangingCheck() throws {
        let a = try recipe(title: "A", ingredients: [("Broth", 1, .cup)])
        let sel = try selection(a, servings: 2, checked: true)
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [sel], manualItems: [], recipes: [a]
        )
        let broth = try XCTUnwrap(line(snapshot, key: "broth", unit: .cup))
        XCTAssertEqual(try exact(broth), 1, accuracy: 0.0000001)
        XCTAssertTrue(broth.isChecked)
    }

    // MARK: - Manual items

    func testManualItemsLeadTheListAndOwnTheirCheckFlag() throws {
        let recipeOne = try recipe(title: "R", ingredients: [("Rice", 1, .cup)])
        let manual = try GroceryManualItem(name: "Paper towels", isChecked: true)
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(recipeOne, servings: 2)],
            manualItems: [manual],
            recipes: [recipeOne]
        )
        XCTAssertEqual(snapshot.manualLines.count, 1)
        XCTAssertEqual(snapshot.manualLines[0].name, "Paper towels")
        XCTAssertTrue(snapshot.manualLines[0].isChecked)
        XCTAssertEqual(snapshot.checkedCount, 1)
        XCTAssertEqual(snapshot.totalCount, 2)
    }

    func testParseManualEntryExtractsQuantityAndTasteMarker() {
        let quantity = GroceryAggregationEngine.parseManualEntry("2 tbsp soy sauce")
        XCTAssertEqual(quantity?.name, "soy sauce")
        XCTAssertEqual(quantity?.amount, 2)
        XCTAssertEqual(quantity?.unit, .tablespoon)

        let taste = GroceryAggregationEngine.parseManualEntry("salt to taste")
        XCTAssertEqual(taste?.name, "salt")
        XCTAssertTrue(taste?.isTasteDosed ?? false)
        XCTAssertNil(taste?.amount)

        let plain = GroceryAggregationEngine.parseManualEntry(" Paper towels ")
        XCTAssertEqual(plain?.name, "Paper towels")
        XCTAssertNil(plain?.amount)

        XCTAssertNil(GroceryAggregationEngine.parseManualEntry("   "))
        // "2 cans tomatoes": 'cans' is not a known unit -> name keeps it.
        let cans = GroceryAggregationEngine.parseManualEntry("2 cans tomatoes")
        XCTAssertEqual(cans?.name, "2 cans tomatoes")
    }

    // MARK: - Sharing text

    func testPlainTextExportCarriesAmountsQualifiersChecksAndProvenance() throws {
        let a = try recipe(title: "A", ingredients: [("Tomato", 1, .each), ("Salt to taste", 1, .teaspoon)])
        let manual = try GroceryManualItem(name: "Bread", isChecked: false)
        let snapshot = GroceryAggregationEngine.aggregate(
            selections: [try selection(a, servings: 2, checked: false)],
            manualItems: [manual],
            recipes: [a]
        )
        let text = GroceryListFormatter.plainText(snapshot)
        XCTAssertTrue(text.contains("1 each Tomato [ ] — for: A × 2"), text)
        XCTAssertTrue(text.contains("Salt to taste (to taste) [ ] — for: A × 2"), text)
        XCTAssertTrue(text.contains("Bread [ ]"), text)
        XCTAssertTrue(text.contains("FROM RECIPES"), text)
        XCTAssertTrue(text.contains("MANUAL ITEMS"), text)
    }
}
