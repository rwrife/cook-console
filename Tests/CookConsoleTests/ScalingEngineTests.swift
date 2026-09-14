import XCTest

@testable import CookConsole

final class ScalingEngineTests: XCTestCase {
    func testHalfScaleAndTwelveTimesScalePreserveIngredientIdentity() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ingredient = try Ingredient(id: id, name: "Flour", amount: 1, unit: .cup)

        let half = try ScalingEngine.scaled(ingredient, ratio: 0.5)
        let twelve = try ScalingEngine.scaled(ingredient, ratio: 12)

        XCTAssertEqual(half.id, id)
        XCTAssertEqual(half.amount, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(twelve.amount, 12, accuracy: 0.000_001)
    }

    func testRecipeScalingUsesServingsRatioAtExtremes() throws {
        let ingredient = try Ingredient(name: "Spice", amount: 0.25, unit: .teaspoon)
        let step = try RecipeStep(instruction: "Mix.")
        let recipe = try Recipe(
            title: "Spice Mix",
            servings: 2,
            ingredients: [ingredient],
            steps: [step]
        )

        XCTAssertEqual(
            try ScalingEngine.scaledIngredients(for: recipe, targetServings: 1).first?.amount,
            0.125
        )
        XCTAssertEqual(
            try ScalingEngine.scaledIngredients(for: recipe, targetServings: 24).first?.amount,
            3
        )
    }

    func testKitchenVolumesSnapToReadableFractions() throws {
        XCTAssertEqual(
            try ScalingEngine.scaledAmount(0.33, unit: .cup, ratio: 1),
            0.375,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try ScalingEngine.scaledAmount(1.13, unit: .tablespoon, ratio: 1),
            1.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try ScalingEngine.scaledAmount(5.26, unit: .teaspoon, ratio: 1),
            5.5,
            accuracy: 0.000_001
        )
    }

    func testMetricUnitsUseMagnitudeSensitiveSteps() throws {
        XCTAssertEqual(try ScalingEngine.scaledAmount(0.83, unit: .liter, ratio: 1), 0.85)
        XCTAssertEqual(try ScalingEngine.scaledAmount(12.3, unit: .gram, ratio: 1), 12)
        XCTAssertEqual(try ScalingEngine.scaledAmount(247, unit: .milliliter, ratio: 1), 245)
    }

    func testOtherUnitsUseSensibleDiscreteSteps() throws {
        XCTAssertEqual(try ScalingEngine.scaledAmount(2.2, unit: .each, ratio: 1), 2)
        XCTAssertEqual(try ScalingEngine.scaledAmount(1.37, unit: .ounce, ratio: 1), 1.25)
        XCTAssertEqual(try ScalingEngine.scaledAmount(0.7, unit: .pound, ratio: 1), 0.75)
    }

    func testZeroNegativeAndNonfiniteInputsAreRejected() {
        for ratio: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try ScalingEngine.scaledAmount(1, unit: .cup, ratio: ratio)
            )
        }
        for amount: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try ScalingEngine.scaledAmount(amount, unit: .cup, ratio: 1)
            )
        }
    }

    func testMultiplicationOverflowAndUnderflowAreRejected() {
        XCTAssertThrowsError(
            try ScalingEngine.scaledAmount(
                .greatestFiniteMagnitude,
                unit: .cup,
                ratio: 2
            )
        ) { error in
            XCTAssertEqual(error as? ScalingError, .resultOutOfRange)
        }
        XCTAssertThrowsError(
            try ScalingEngine.scaledAmount(
                .leastNonzeroMagnitude,
                unit: .cup,
                ratio: .leastNonzeroMagnitude
            )
        ) { error in
            XCTAssertEqual(error as? ScalingError, .resultOutOfRange)
        }
    }

    func testInvalidTargetServingsAreRejected() throws {
        let ingredient = try Ingredient(name: "Flour", amount: 1, unit: .cup)
        let step = try RecipeStep(instruction: "Mix.")
        let recipe = try Recipe(
            title: "Bread",
            servings: 4,
            ingredients: [ingredient],
            steps: [step]
        )

        for servings: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try ScalingEngine.scaledIngredients(for: recipe, targetServings: servings)
            )
        }
    }
}
