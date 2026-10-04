import XCTest

@testable import CookConsole

/// Issue #21: editorial audit unit tests. Every check must fire on a
/// deliberate defect and stay silent on clean editorial prose —
/// the false-positive direction is what makes or breaks trust in the
/// gate, so both directions are asserted per rule.
final class RecipeEditorialAuditTests: XCTestCase {
    private func recipe(
        title: String = "Test Recipe",
        ingredients: [(String, Double, IngredientUnit)],
        steps: [(String, TimeInterval?)]
    ) throws -> Recipe {
        try Recipe(
            title: title,
            servings: 4,
            ingredients: ingredients.map {
                try Ingredient(name: $0.0, amount: $0.1, unit: $0.2)
            },
            steps: steps.map {
                try RecipeStep(instruction: $0.0, timerDuration: $0.1)
            }
        )
    }

    // MARK: - Ingredient ↔ instruction cross-check (AC #1)

    func testIngredientAbsentFromInstructionsIsBlocking() throws {
        let subject = try recipe(
            ingredients: [("Olive oil", 2, .tablespoon), ("Capers", 1, .tablespoon)],
            steps: [("Warm the olive oil in a pan.", nil)]
        )
        let findings = RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.kind == .ingredientAbsentFromInstructions }
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].message.contains("Capers"))
        XCTAssertEqual(findings[0].severity, .blocking)
    }

    func testPluralAndPartNameVariantsCountAsMentions() throws {
        // Listed "Carrot"; instruction says "carrots" — naive plural is a
        // mention, not a false positive.
        let subject = try recipe(
            ingredients: [("Carrot", 3, .each), ("Garlic cloves", 2, .each)],
            steps: [("Roast the carrots with crushed garlic.", nil)]
        )
        XCTAssertTrue(
            RecipeEditorialAudit.audit(recipe: subject)
                .filter { $0.kind == .ingredientAbsentFromInstructions }
                .isEmpty
        )
    }

    func testOnionDescriptorMatchesBareOnionMention() throws {
        let subject = try recipe(
            ingredients: [("Onion, diced", 1, .each)],
            steps: [("Soften the onion over medium heat until translucent.", 300)]
        )
        XCTAssertTrue(
            RecipeEditorialAudit.audit(recipe: subject)
                .filter { $0.kind == .ingredientAbsentFromInstructions }
                .isEmpty
        )
    }

    func testUnlistedGlossaryIngredientInInstructionIsBlocking() throws {
        let subject = try recipe(
            ingredients: [("Pasta", 400, .gram)],
            steps: [("Boil the pasta until al dente.", 600), ("Stir in frozen peas.", nil)]
        )
        let findings = RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.kind == .instructionMentionsUnlistedIngredient }
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].message.contains("pea"))
    }

    func testVerbVocabularyIsNeverFlaggedAsIngredient() throws {
        // "whisk", "simmer", "fold" are instructions, not ingredients.
        let subject = try recipe(
            ingredients: [("Flour", 2, .cup)],
            steps: [("Whisk the flour with water until smooth.", nil)]
        )
        XCTAssertTrue(
            RecipeEditorialAudit.audit(recipe: subject)
                .filter { $0.kind == .instructionMentionsUnlistedIngredient }
                .isEmpty
        )
    }

    func testSaltAndWaterAreExemptInBothDirections() throws {
        let subject = try recipe(
            ingredients: [("Pasta", 400, .gram), ("Salt", 1, .teaspoon)],
            steps: [
                ("Boil the pasta in salted water until al dente.", 600),
                ("Drain, then season with salt and pepper.", nil),
            ]
        )
        let findings = RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.severity == .blocking }
        XCTAssertTrue(
            findings.filter { $0.kind == .ingredientAbsentFromInstructions }.isEmpty,
            "salt is exempt: \(findings)"
        )
        XCTAssertTrue(
            findings.filter { $0.kind == .instructionMentionsUnlistedIngredient }.isEmpty,
            "salt/pepper/water never flagged: \(findings)"
        )
    }

    func testEditorialExceptionSuppressesOnlyItsOwnFinding() throws {
        let subject = try recipe(
            ingredients: [("Flour", 2, .cup), ("Milk", 1, .cup)],
            steps: [("Whisk ingredients into a smooth batter.", nil)]
        )
        // Both absent before exception...
        let before = Set(RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.kind == .ingredientAbsentFromInstructions }
            .map { $0.message })
        XCTAssertEqual(before.count, 2)
        // ...only flour after.
        let after = RecipeEditorialAudit.audit(recipe: subject, editorialExceptions: ["flour"])
            .filter { $0.kind == .ingredientAbsentFromInstructions }
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0].message.contains("Milk"))
    }

    // MARK: - Oven temperature (AC #2, equipment/temperature coverage)

    func testOvenHeatWithoutTemperatureIsBlocking() throws {
        let subject = try recipe(
            ingredients: [("Potato", 4, .each)],
            steps: [("Heat the oven. Roast the potatoes until golden.", 1800)]
        )
        XCTAssertTrue(
            RecipeEditorialAudit.audit(recipe: subject)
                .contains { $0.kind == .missingOvenTemperature }
        )
    }

    func testStatedOvenTemperaturePasses() throws {
        let subject = try recipe(
            ingredients: [("Potato", 4, .each)],
            steps: [
                ("Heat the oven to 200°C.", nil),
                ("Roast the potatoes until golden.", 1800),
            ]
        )
        XCTAssertFalse(
            RecipeEditorialAudit.audit(recipe: subject)
                .contains { $0.kind == .missingOvenTemperature }
        )
    }

    func testOvenCleaningStepNeedsNoTemperature() throws {
        let subject = try recipe(
            ingredients: [("Potato", 4, .each)],
            steps: [
                ("Heat the oven to 220°C.", nil),
                ("Roast the potatoes until tender.", 1800),
                ("While hot, wipe spills inside the oven.", nil),
            ]
        )
        XCTAssertFalse(
            RecipeEditorialAudit.audit(recipe: subject)
                .contains { $0.kind == .missingOvenTemperature }
        )
    }

    // MARK: - Timer sanity + doneness (AC #3)

    func testImplausibleTimersAreBlocking() throws {
        let subject = try recipe(
            ingredients: [("Rice", 1, .cup)],
            steps: [
                ("Rinse the rice.", 2),
                ("Simmer the rice until tender.", 40000),
            ]
        )
        let findings = RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.kind == .timerOutOfRange }
        XCTAssertEqual(findings.count, 2)
    }

    func testTimeOnlyStepGetsDonenessAdvisory() throws {
        let subject = try recipe(
            ingredients: [("Rice", 1, .cup)],
            steps: [("Cook the rice.", 600)]
        )
        let findings = RecipeEditorialAudit.audit(recipe: subject)
            .filter { $0.kind == .timeOnlyDoneness }
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .advisory)
        // An advisory never blocks the gate.
        XCTAssertTrue(RecipeEditorialAudit.isEditoriallyClean(recipe: subject))
    }

    func testDonenessCueSilencesTheAdvisory() throws {
        let withCue = try recipe(
            ingredients: [("Rice", 1, .cup)],
            steps: [("Simmer the rice until the water is absorbed and the grains are tender.", 600)]
        )
        XCTAssertFalse(
            RecipeEditorialAudit.audit(recipe: withCue)
                .contains { $0.kind == .timeOnlyDoneness }
        )
    }

    func testAlDenteCountsAsDonenessCue() throws {
        let subject = try recipe(
            ingredients: [("Pasta", 400, .gram)],
            steps: [("Boil the pasta in salted water until al dente.", 600)]
        )
        XCTAssertFalse(
            RecipeEditorialAudit.audit(recipe: subject)
                .contains { $0.kind == .timeOnlyDoneness }
        )
    }

    func testAuditIsDeterministic() throws {
        let subject = try recipe(
            ingredients: [("Capers", 1, .tablespoon), ("Anchovy", 2, .each)],
            steps: [("Heat the oven. Stir everything.", 3)]
        )
        XCTAssertEqual(
            RecipeEditorialAudit.audit(recipe: subject),
            RecipeEditorialAudit.audit(recipe: subject)
        )
    }
}
