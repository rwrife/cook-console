import XCTest

@testable import CookConsole

final class ScalingEngineTests: XCTestCase {
    func testScalingKeepsExactAmountsAndIngredientIdentity() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ingredient = try Ingredient(id: id, name: "Flour", amount: 1.1, unit: .cup)

        let scaled = try ScalingEngine.scaled(ingredient, ratio: 1.5)

        XCTAssertEqual(scaled.id, id)
        XCTAssertEqual(scaled.exactAmount, 1.65, accuracy: 0.000_000_001)
        XCTAssertEqual(scaled.displayAmount, 1.75, accuracy: 0.000_000_001)
        XCTAssertTrue(scaled.wasRoundedForDisplay)
    }

    func testRecipeScalingAlwaysUsesOriginalAmountsWithoutAccumulatedRounding() throws {
        let recipe = try makeRecipe(
            servings: 4,
            ingredients: [try Ingredient(name: "Flour", amount: 1.1, unit: .cup)]
        )

        let six = try ScalingEngine.scaledIngredients(for: recipe, targetServings: 6)[0]
        let eight = try ScalingEngine.scaledIngredients(for: recipe, targetServings: 8)[0]
        let sixAgain = try ScalingEngine.scaledIngredients(for: recipe, targetServings: 6)[0]

        XCTAssertEqual(six.exactAmount, 1.65, accuracy: 0.000_000_001)
        XCTAssertEqual(eight.exactAmount, 2.2, accuracy: 0.000_000_001)
        XCTAssertEqual(sixAgain.exactAmount, six.exactAmount, accuracy: 0.000_000_001)
    }

    func testDisplayRecommendationsAreUnitAware() throws {
        let volume = try ScalingEngine.scaled(
            Ingredient(name: "Milk", amount: 0.33, unit: .cup), ratio: 1
        )
        let metric = try ScalingEngine.scaled(
            Ingredient(name: "Flour", amount: 247, unit: .gram), ratio: 1
        )
        let count = try ScalingEngine.scaled(
            Ingredient(name: "Eggs", amount: 1.3, unit: .each), ratio: 1
        )

        XCTAssertEqual(volume.displayAmount, 0.375)
        XCTAssertEqual(metric.displayAmount, 245)
        XCTAssertEqual(count.displayAmount, 1.25)
        XCTAssertEqual(volume.unit, .cup)
        XCTAssertEqual(metric.unit, .gram)
        XCTAssertEqual(count.unit, .each)
    }

    func testPositiveTinyAmountsNeverDisplayAsZero() throws {
        for unit in IngredientUnit.allCases {
            let result = try ScalingEngine.scaled(
                Ingredient(name: "Tiny", amount: 0.000_001, unit: unit), ratio: 0.001
            )
            XCTAssertGreaterThan(result.exactAmount, 0)
            XCTAssertGreaterThan(result.displayAmount, 0, "\(unit) displayed as zero")
        }
    }

    func testFractionalEggGuidanceExplainsHowToMeasureIt() throws {
        let egg = try ScalingEngine.scaled(
            Ingredient(name: "Large eggs", amount: 3, unit: .each), ratio: 0.5
        )

        XCTAssertEqual(egg.displayAmount, 1.5)
        XCTAssertEqual(
            try XCTUnwrap(egg.actionableGuidance),
            "Beat 2 eggs together, then use about 3/4 of the mixture for 1 1/2 eggs."
        )
    }

    func testFractionalEggBelowOneBeatssMinimumOneEgg() throws {
        let egg = try ScalingEngine.scaled(
            Ingredient(name: "Egg", amount: 1, unit: .each), ratio: 0.25
        )

        XCTAssertEqual(egg.displayAmount, 0.25)
        XCTAssertTrue(
            try XCTUnwrap(egg.actionableGuidance).hasPrefix("Beat 1 egg together")
        )
    }

    func testOtherFractionalCountGuidanceOffersWholeItemChoice() throws {
        let tomato = try ScalingEngine.scaled(
            Ingredient(name: "Tomatoes", amount: 3, unit: .each), ratio: 0.5
        )

        XCTAssertEqual(
            tomato.actionableGuidance,
            "Use 1 1/2 tomatoes when it can be divided; otherwise choose 1 or 2 whole based on the recipe."
        )
    }

    func testWholeCountsAndMeasuredUnitsDoNotClaimIndivisibleGuidance() throws {
        let egg = try ScalingEngine.scaled(
            Ingredient(name: "Eggs", amount: 2, unit: .each), ratio: 2
        )
        let flour = try ScalingEngine.scaled(
            Ingredient(name: "Flour", amount: 1.5, unit: .cup), ratio: 1
        )

        XCTAssertNil(egg.actionableGuidance)
        XCTAssertNil(flour.actionableGuidance)
    }

    func testSmallAndLargeMultipliersStayFiniteAndExact() throws {
        let ingredient = try Ingredient(name: "Spice", amount: 0.25, unit: .teaspoon)
        let tiny = try ScalingEngine.scaled(ingredient, ratio: 0.01)
        let large = try ScalingEngine.scaled(ingredient, ratio: 100)

        XCTAssertEqual(tiny.exactAmount, 0.0025, accuracy: 0.000_000_001)
        XCTAssertEqual(large.exactAmount, 25, accuracy: 0.000_000_001)
    }

    func testIncompatibleUnitsAreNeverConvertedOrCombined() throws {
        let recipe = try makeRecipe(
            servings: 2,
            ingredients: [
                try Ingredient(name: "Milk", amount: 1, unit: .cup),
                try Ingredient(name: "Flour", amount: 100, unit: .gram),
            ]
        )

        let result = try ScalingEngine.scaledIngredients(for: recipe, targetServings: 3)

        XCTAssertEqual(result.map(\.unit), [.cup, .gram])
        XCTAssertEqual(result.map(\.exactAmount), [1.5, 150])
    }

    func testZeroNegativeNonfiniteAndOverflowInputsAreRejected() throws {
        let ingredient = try Ingredient(name: "Flour", amount: 1, unit: .cup)
        for ratio: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try ScalingEngine.scaled(ingredient, ratio: ratio))
        }
        XCTAssertThrowsError(
            try ScalingEngine.scaled(
                Ingredient(name: "Flour", amount: .greatestFiniteMagnitude, unit: .cup),
                ratio: 2
            )
        ) { error in
            XCTAssertEqual(error as? ScalingError, .resultOutOfRange)
        }
    }

    func testInvalidTargetServingsAreRejected() throws {
        let recipe = try makeRecipe(
            servings: 4,
            ingredients: [try Ingredient(name: "Flour", amount: 1, unit: .cup)]
        )

        for servings: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try ScalingEngine.scaledIngredients(for: recipe, targetServings: servings)
            )
        }
    }

    private func makeRecipe(servings: Double, ingredients: [Ingredient]) throws -> Recipe {
        try Recipe(
            title: "Test Recipe",
            servings: servings,
            ingredients: ingredients,
            steps: [try RecipeStep(instruction: "Cook.")]
        )
    }
}
