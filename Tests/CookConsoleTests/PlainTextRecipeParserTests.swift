import XCTest

@testable import CookConsole

final class PlainTextRecipeParserTests: XCTestCase {
    func testParsesCompleteRecipeWithFractionsAliasesAndTags() throws {
        let text = """
        Title: Weeknight Pancakes
        Servings: 4
        Tags: breakfast, Quick, breakfast

        Ingredients:
        - 1 1/2 cups flour
        - 2 each eggs
        - 0.5 tsp salt
        Steps:
        1. Whisk the ingredients.
        2. Cook on a hot griddle.
        """

        let recipe = try PlainTextRecipeParser.parse(text)

        XCTAssertEqual(recipe.title, "Weeknight Pancakes")
        XCTAssertEqual(recipe.servings, 4)
        XCTAssertEqual(recipe.tags, ["breakfast", "Quick"])
        XCTAssertEqual(recipe.ingredients.map(\.amount), [1.5, 2, 0.5])
        XCTAssertEqual(recipe.ingredients.map(\.unit), [.cup, .each, .teaspoon])
        XCTAssertEqual(recipe.steps.map(\.instruction), [
            "Whisk the ingredients.",
            "Cook on a hot griddle.",
        ])
        XCTAssertFalse(recipe.isFavorite)
    }

    func testParsesSlashFractionAndSupportedMetricUnit() throws {
        let recipe = try PlainTextRecipeParser.parse("""
        Title: Dressing
        Servings: 2
        Ingredients:
        - 3/4 tbsp oil
        - 250 mL water
        Steps:
        1) Shake together.
        """)

        XCTAssertEqual(recipe.ingredients[0].amount, 0.75)
        XCTAssertEqual(recipe.ingredients[0].unit, .tablespoon)
        XCTAssertEqual(recipe.ingredients[1].unit, .milliliter)
    }

    func testRejectsSignedNonintegralNonfiniteAndMalformedFractionComponents() {
        let invalidAmounts = [
            "+1", "+1.5", "-1", "nan", "inf", "1e2", "1.2.3",
            "-1/-2", "+1/2", "1/-2", "1/+2", "1.5/2", "1/2.5",
            "nan/2", "1/inf", "1/", "/2", "1//2", "999999999999999999999999/2",
            "-1 1/2", "+1 1/2", "1.5 1/2", "1 0/2", "1 2/2", "1 3/2",
            "999999999999999999999999 1/2",
        ]

        for amount in invalidAmounts {
            assertParseError(
                """
                Title: Soup
                Servings: 2
                Ingredients:
                - \(amount) cups water
                Steps:
                1. Stir.
                """,
                line: 4,
                containing: "amount"
            )
        }
    }

    func testAcceptsZeroWholeWithProperMixedFraction() throws {
        let recipe = try PlainTextRecipeParser.parse("""
        Title: Soup
        Servings: 2
        Ingredients:
        - 0 1/2 cup water
        Steps:
        1. Stir.
        """)

        XCTAssertEqual(recipe.ingredients[0].amount, 0.5)
    }

    func testRejectsInputBeyondDocumentedResourceLimits() {
        assertParseError(
            String(repeating: "x", count: PlainTextRecipeParser.maximumUTF8ByteCount + 1),
            line: 1,
            containing: "bytes"
        )
        assertParseError(
            String(repeating: "\n", count: PlainTextRecipeParser.maximumLineCount),
            line: PlainTextRecipeParser.maximumLineCount + 1,
            containing: "lines"
        )

        let ingredients = Array(
            repeating: "- 1 cup water",
            count: PlainTextRecipeParser.maximumIngredientCount + 1
        ).joined(separator: "\n")
        assertParseError(
            "Title: Soup\nServings: 2\nIngredients:\n\(ingredients)\nSteps:\n1. Stir.",
            line: PlainTextRecipeParser.maximumIngredientCount + 4,
            containing: "ingredients"
        )

        let steps = (1...(PlainTextRecipeParser.maximumStepCount + 1))
            .map { "\($0). Stir." }
            .joined(separator: "\n")
        assertParseError(
            "Title: Soup\nServings: 2\nIngredients:\n- 1 cup water\nSteps:\n\(steps)",
            line: PlainTextRecipeParser.maximumStepCount + 6,
            containing: "steps"
        )
    }

    func testCRLFInputReportsLogicalLineNumber() {
        assertParseError(
            "Title: Soup\r\nServings: 2\r\nIngredients:\r\n- 1 bucket water\r\nSteps:\r\n1. Stir.",
            line: 4,
            containing: "unit"
        )
    }

    func testInvalidServingsReportsSourceLine() {
        assertParseError("""
        Title: Soup
        Servings: many
        Ingredients:
        - 1 cup water
        Steps:
        1. Stir.
        """, line: 2, containing: "servings")
    }

    func testUnknownIngredientUnitReportsSourceLine() {
        assertParseError("""
        Title: Soup
        Servings: 2
        Ingredients:
        - 1 bucket water
        Steps:
        1. Stir.
        """, line: 4, containing: "unit")
    }

    func testNonfiniteIngredientAmountReportsSourceLine() {
        assertParseError("""
        Title: Soup
        Servings: 2
        Ingredients:
        - nan cup water
        Steps:
        1. Stir.
        """, line: 4, containing: "amount")
    }

    func testMalformedIngredientReportsSourceLine() {
        assertParseError("""
        Title: Soup
        Servings: 2
        Ingredients:
        water
        Steps:
        1. Stir.
        """, line: 4, containing: "ingredient")
    }

    func testStepNumbersMustBeSequentialAndReportsSourceLine() {
        assertParseError("""
        Title: Soup
        Servings: 2
        Ingredients:
        - 1 cup water
        Steps:
        2. Stir.
        """, line: 6, containing: "step 1")
    }

    func testMissingSectionHasClearEndOfInputError() {
        assertParseError("""
        Title: Soup
        Servings: 2
        Ingredients:
        - 1 cup water
        """, line: 4, containing: "Steps:")
    }

    private func assertParseError(
        _ text: String,
        line: Int,
        containing fragment: String,
        file: StaticString = #filePath,
        testLine: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PlainTextRecipeParser.parse(text),
            file: file,
            line: testLine
        ) { error in
            guard let importError = error as? RecipeImportError else {
                return XCTFail("Expected RecipeImportError, got \(error)", file: file, line: testLine)
            }
            XCTAssertEqual(importError.line, line, file: file, line: testLine)
            XCTAssertTrue(
                importError.reason.localizedCaseInsensitiveContains(fragment),
                "Expected '\(importError.reason)' to contain '\(fragment)'",
                file: file,
                line: testLine
            )
        }
    }
}
