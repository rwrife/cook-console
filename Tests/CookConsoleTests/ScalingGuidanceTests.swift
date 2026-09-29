import XCTest

@testable import CookConsole

final class ScalingGuidanceTests: XCTestCase {
    func testBakingRecipeScalingOffersPanAndBakingLimitsGuidance() throws {
        let recipe = try Recipe(
            title: "Classic Yellow Cake",
            servings: 8,
            ingredients: [
                try Ingredient(name: "Flour", amount: 2, unit: .cup),
                try Ingredient(name: "Sugar", amount: 1.5, unit: .cup),
                try Ingredient(name: "Eggs", amount: 3, unit: .each),
            ],
            steps: [
                try RecipeStep(instruction: "Bake at 350F for 30 minutes.", timerDuration: 1800),
            ],
            tags: ["baking", "cake"]
        )

        let guidance = ScalingLimitsGuidance.guidance(for: recipe, targetServings: 16)

        XCTAssertEqual(guidance.ratio, 2.0)
        XCTAssertTrue(guidance.isBakingRecipe)
        XCTAssertEqual(
            guidance.panSizeGuidance,
            "Baking scaled 2x: bake in two 8-inch or 9-inch pans rather than a single deeper pan so the center bakes evenly."
        )
        XCTAssertEqual(
            guidance.batchGuidance,
            "Double batch: prepare batter in two separate batches if bowl or mixer capacity is crowded."
        )
        XCTAssertEqual(
            guidance.cookingTimeGuidance,
            "Do not double baking time. Cooking time depends on pan depth; check for doneness around the original 30 min (usually within ±5 minutes)."
        )
    }

    func testHalvingBakingRecipeRecommendsSmallerPansAndEarlierChecks() throws {
        let recipe = try Recipe(
            title: "Quick Bread",
            servings: 8,
            ingredients: [try Ingredient(name: "Flour", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Bake.", timerDuration: 2400)],
            tags: ["baking"]
        )

        let guidance = ScalingLimitsGuidance.guidance(for: recipe, targetServings: 4)

        XCTAssertEqual(guidance.ratio, 0.5)
        XCTAssertTrue(guidance.isBakingRecipe)
        XCTAssertEqual(
            guidance.panSizeGuidance,
            "Baking scaled 0.5x: use a smaller pan (e.g. mini-loaf or 6-inch pan) so batter depth matches the original recipe."
        )
        XCTAssertEqual(
            guidance.cookingTimeGuidance,
            "Do not cut baking time in half linearly. Check doneness 5–10 minutes earlier than the original 40 min."
        )
    }

    func testNonBakingRecipeOffersPanAndCrowdingGuidanceWhenScaledUp() throws {
        let recipe = try Recipe(
            title: "Skillet Stir-Fry",
            servings: 2,
            ingredients: [
                try Ingredient(name: "Chicken", amount: 1, unit: .pound),
                try Ingredient(name: "Broccoli", amount: 2, unit: .cup),
            ],
            steps: [
                try RecipeStep(instruction: "Sear quickly.", timerDuration: 600),
            ],
            tags: ["dinner", "skillet"]
        )

        let guidance = ScalingLimitsGuidance.guidance(for: recipe, targetServings: 6)

        XCTAssertEqual(guidance.ratio, 3.0)
        XCTAssertFalse(guidance.isBakingRecipe)
        XCTAssertEqual(
            guidance.panSizeGuidance,
            "Cooking scaled 3x: use a wider skillet or Dutch oven so ingredients sear instead of steaming."
        )
        XCTAssertEqual(
            guidance.batchGuidance,
            "Batch cooking: cook in multiple batches rather than crowding a single pan."
        )
        XCTAssertEqual(
            guidance.cookingTimeGuidance,
            "Do not scale cooking time linearly (3x). Searing time stays similar; allow a few extra minutes for batching or reaching a simmer."
        )
    }

    func testUnscaledRecipeHasNoScalingDisclosures() throws {
        let recipe = try Recipe(
            title: "Simple Soup",
            servings: 4,
            ingredients: [try Ingredient(name: "Water", amount: 4, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer.", timerDuration: 600)]
        )

        let guidance = ScalingLimitsGuidance.guidance(for: recipe, targetServings: 4)

        XCTAssertEqual(guidance.ratio, 1.0)
        XCTAssertNil(guidance.panSizeGuidance)
        XCTAssertNil(guidance.batchGuidance)
        XCTAssertNil(guidance.cookingTimeGuidance)
        XCTAssertFalse(guidance.hasGuidance)
    }

    func testRecipeSpecificGuidanceOverridesGenericAdvice() throws {
        let recipe = try Recipe(
            title: "Family Cake",
            servings: 8,
            ingredients: [try Ingredient(name: "Flour", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Bake.", timerDuration: 1_800)],
            tags: ["baking"],
            panSizeGuidance: "Use the two 7-inch pans tested for this recipe.",
            batchSizeGuidance: "Make two separate batters.",
            cookingTimeGuidance: "Start checking both pans at 24 minutes."
        )

        let guidance = ScalingLimitsGuidance.guidance(for: recipe, targetServings: 16)

        XCTAssertEqual(guidance.panSizeGuidance, "Use the two 7-inch pans tested for this recipe.")
        XCTAssertEqual(guidance.batchGuidance, "Make two separate batters.")
        XCTAssertEqual(guidance.cookingTimeGuidance, "Start checking both pans at 24 minutes.")
    }
}
