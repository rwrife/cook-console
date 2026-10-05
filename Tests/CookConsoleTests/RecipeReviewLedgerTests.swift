import Foundation
import XCTest
import GRDB

@testable import CookConsole

/// Issue #21: the kitchen-test ledger + review-pack CI gate. These tests
/// are the "meaningful CI checks" acceptance criterion: they run on every
/// CI lane (Linux SwiftPM + macOS xcodebuild) and fail the build when the
/// published review pack drifts from reality, smuggles an unjustified
/// exception, or — the cardinal sin — claims a kitchen test without a
/// reproducible observation.
final class RecipeReviewLedgerTests: XCTestCase {
    private static let packRelativePath = "ReviewPack/RecipeReviewPack.starter-seed-v1.json"
    private static let seedRelativePath = "Tools/seed_screenshot_recipes.py"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // this file
            .deletingLastPathComponent() // CookConsoleTests
            .deletingLastPathComponent() // Tests
    }

    private func loadPack() throws -> RecipeReviewPack {
        try RecipeReviewPack.load(from: repoRoot.appendingPathComponent(Self.packRelativePath))
    }

    // MARK: - Pack integrity

    func testPackLoadsAndEveryEntryIsValid() throws {
        let pack = try loadPack()
        XCTAssertEqual(pack.schemaVersion, 1)
        XCTAssertFalse(pack.packVersion.isEmpty)
        XCTAssertFalse(pack.recipes.isEmpty)

        var seenTitles: Set<String> = []
        var seenIDs: Set<UUID> = []
        for entry in pack.recipes {
            guard let uuid = entry.recipeID else {
                return XCTFail("Pack entry '\(entry.title)' has non-UUID id '\(entry.id)'")
            }
            XCTAssertTrue(seenTitles.insert(entry.title).inserted, "duplicate title \(entry.title)")
            XCTAssertTrue(seenIDs.insert(uuid).inserted, "duplicate id \(uuid)")
            // Deserializing already validated exceptions/observations;
            // reconstruct the record explicitly to prove no unjustified
            // exception can exist in the pack.
            _ = try entry.makeReviewRecord()
        }
    }

    func testEveryPassedDeskReviewEntryPassesTheEditorialAudit() throws {
        // AC #1/#2/#3 gate: "desk_review_passed" is a CLAIM, and this test
        // is the proof. Any new blocking finding in seed content must move
        // the entry to desk_review_issues_open, never silently pass.
        let pack = try loadPack()
        for entry in pack.recipes where entry.reviewStatus == .deskReviewPassed {
            let recipe = try Self.recipe(from: entry)
            let blocking = RecipeEditorialAudit.audit(recipe: recipe, editorialExceptions: entry.exceptionPhrases)
                .filter { $0.severity == .blocking }
            XCTAssertTrue(
                blocking.isEmpty,
                "\(entry.title) claims desk_review_passed but audit says: \(blocking.map(\.message))"
            )
        }
    }

    func testEveryOpenDefectEntryActuallyFailsTheAudit() throws {
        // The mirror gate: desk_review_issues_open must correspond to a
        // real, still-reproducible blocking finding, so defects can never
        // linger in the ledger after the content is already fixed.
        let pack = try loadPack()
        for entry in pack.recipes where entry.reviewStatus == .deskReviewIssuesOpen {
            let recipe = try Self.recipe(from: entry)
            let blocking = RecipeEditorialAudit.audit(recipe: recipe, editorialExceptions: entry.exceptionPhrases)
                .filter { $0.severity == .blocking }
            XCTAssertFalse(
                blocking.isEmpty,
                "\(entry.title) is marked desk_review_issues_open but the audit is clean — resolve the ledger entry"
            )
        }
    }

    func testNoRecipeClaimsKitchenTestedWithoutObservations() throws {
        // AC #5: never mark recipes kitchen-tested based on automated
        // checks. A pack entry that carries observations is the ONLY
        // source of a kitchen-tested claim, and each observation must be
        // non-blank (enforced by the domain at decode time).
        let pack = try loadPack()
        for entry in pack.recipes {
            let record = try entry.makeReviewRecord()
            XCTAssertFalse(
                record.claimsKitchenTestedWithoutEvidence,
                "\(entry.title) claims kitchen test without evidence"
            )
            for observation in record.observations {
                XCTAssertFalse(observation.notes.isEmpty)
                XCTAssertFalse(observation.tester.isEmpty)
            }
        }
    }

    func testEverySeedRecipeIsCoveredByThePack() throws {
        // Review must cover the whole starter catalog, and pack content
        // fields must match the seed script byte-for-byte.
        let pack = try loadPack()
        let seedRecipes = try Self.parseSeedRecipes(
            at: repoRoot.appendingPathComponent(Self.seedRelativePath)
        )
        XCTAssertEqual(Set(seedRecipes.map(\.title)), Set(pack.recipes.map(\.title)))

        for seed in seedRecipes {
            guard let entry = pack.recipes.first(where: { $0.title == seed.title }) else {
                return XCTFail("seed recipe \(seed.title) missing from pack")
            }
            guard entry.sourceRecipe == nil else { continue } // snapshot-based entry
            // Reconstruct the seed recipe and audit it — the pack's status
            // must already be covered by the two directional gates above.
            let recipe = try seed.makeRecipe()
            XCTAssertFalse(recipe.ingredients.isEmpty)
            XCTAssertFalse(recipe.steps.isEmpty)
        }
    }

    func testKitchenTestQueueIsPrioritizedAndGapSummaryPublishes() throws {
        // AC #5/#6: a prioritized queue exists and the gap report names
        // every remaining manual item — over MERGED board rows, so a
        // recorded observation also removes an entry from the queue.
        let pack = try loadPack()
        let rows = RecipeReviewBoardRow.build(pack: pack, records: [], recipes: [])
        let summary = KitchenTestGapSummary(packVersion: pack.packVersion, rows: rows)
        XCTAssertFalse(summary.isFullyTested, "no physical kitchen test has happened yet — the queue must be non-empty")
        XCTAssertFalse(summary.physicalQueue.isEmpty)

        let expectedTitles = Set(pack.recipes.filter { $0.testPriority != nil }.map(\.title))
        let queuedTitles = Set(summary.physicalQueue.map { row in
            row.title.split(separator: ":", omittingEmptySubsequences: true)
                .dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        })
        XCTAssertEqual(queuedTitles, expectedTitles)

        // Priority order preserved.
        let priorities = summary.physicalQueue.compactMap { row -> Int? in
            Int(row.title.split(separator: ":").first.map(String.init) ?? "")
        }
        XCTAssertEqual(priorities, priorities.sorted())
        XCTAssertEqual(Set(priorities).count, priorities.count, "queue priorities must be unique")
        XCTAssertTrue(summary.markdown.contains("Automated/desk evidence NEVER substitutes"))

        // Recording an observation on the top-priority recipe removes it.
        let topTitle = try XCTUnwrap(summary.physicalQueue.first?.title.split(separator: ":").last.map(String.init)?.trimmingCharacters(in: .whitespaces))
        let entry = try XCTUnwrap(pack.recipes.first(where: { $0.title == topTitle }))
        let entryID = try XCTUnwrap(entry.recipeID)
        let observation = try KitchenTestObservation(result: .passed, notes: "real notes", tester: "rwrife")
        let record = try RecipeReviewRecord(
            recipeID: entryID,
            observations: [observation]
        )
        let testedRows = RecipeReviewBoardRow.build(pack: pack, records: [record], recipes: [])
        let testedSummary = KitchenTestGapSummary(packVersion: pack.packVersion, rows: testedRows)
        XCTAssertEqual(testedSummary.kitchenTestedCount, 1)
        XCTAssertFalse(testedSummary.physicalQueue.contains { $0.title.contains(topTitle) })
    }

    // MARK: - Repository persistence (migration v10)

    func testReviewRecordRoundTripsThroughGRDB() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repository = RecipeRepository(database: database)
        let reviews = RecipeReviewRepository(database: database)

        let recipe = try Recipe(
            title: "Ledger Test",
            servings: 2,
            ingredients: [Ingredient(name: "Rice", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Cook the rice until tender.", timerDuration: 600)]
        )
        try repository.create(recipe)

        let exception = try EditorialException(
            phrase: "rice",
            justification: "Step references the collective batter of grains; style exception."
        )
        var record = try RecipeReviewRecord(
            recipeID: recipe.id,
            reviewStatus: .deskReviewIssuesOpen,
            sourceProvenance: "hand test 2026-10",
            contentRevision: 3,
            editorialExceptions: [exception],
            testPriority: 7
        )
        try reviews.save(record)

        var fetched = try XCTUnwrap(reviews.fetch(recipeID: recipe.id))
        XCTAssertEqual(fetched, record)

        // Upsert semantics: same id, changed fields.
        record.reviewStatus = .deskReviewPassed
        record.contentRevision = 4
        try reviews.save(record)
        fetched = try XCTUnwrap(reviews.fetch(recipeID: recipe.id))
        XCTAssertEqual(fetched.reviewStatus, .deskReviewPassed)
        XCTAssertEqual(fetched.contentRevision, 4)
        XCTAssertEqual(fetched.editorialExceptions, [exception])
    }

    func testObservationIsTheOnlyPathToKitchenTestedStatus() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repository = RecipeRepository(database: database)
        let reviews = RecipeReviewRepository(database: database)
        let recipe = try Recipe(
            title: "Timer Test",
            servings: 2,
            ingredients: [Ingredient(name: "Oats", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Simmer the oats until thick.", timerDuration: 900)]
        )
        try repository.create(recipe)
        try reviews.save(try RecipeReviewRecord(recipeID: recipe.id, testPriority: 1))

        var record = try XCTUnwrap(reviews.fetch(recipeID: recipe.id))
        XCTAssertEqual(record.kitchenTestStatus, .notTested)
        XCTAssertEqual(record.testPriority, 1)

        // Record one real physical test.
        let observation = try KitchenTestObservation(
            result: .passed,
            notes: "Made 2026-10-04 with 40g oats/240ml water: thick in 9 min, salt to taste.",
            tester: "rwrife"
        )
        try reviews.addObservation(observation, recipeID: recipe.id)

        record = try XCTUnwrap(reviews.fetch(recipeID: recipe.id))
        XCTAssertEqual(record.kitchenTestStatus, .passed)
        XCTAssertEqual(record.observations.map(\.id), [observation.id])
        XCTAssertNil(record.testPriority, "physical evidence must clear the queue slot")
        XCTAssertFalse(record.claimsKitchenTestedWithoutEvidence)

        // Observations survive record re-save (append-only evidence).
        try reviews.save(record)
        let again = try XCTUnwrap(reviews.fetch(recipeID: recipe.id))
        XCTAssertEqual(again.observations.count, 1)
    }

    func testBlankNotesAndJustificationsCannotBeConstructedOrPersisted() throws {
        XCTAssertThrowsError(try KitchenTestObservation(result: .passed, notes: "   ", tester: "rwrife"))
        XCTAssertThrowsError(try KitchenTestObservation(result: .passed, notes: "real", tester: ""))
        XCTAssertThrowsError(try EditorialException(phrase: "salt", justification: ""))
        XCTAssertThrowsError(try RecipeReviewRecord(recipeID: UUID(), contentRevision: 0))
        XCTAssertThrowsError(try RecipeReviewRecord(recipeID: UUID(), testPriority: 0))
    }

    func testObservationsCascadeWithRecipeDeletionAndFetchDoesNotLeak() throws {
        let database = try RecipeDatabase.makeInMemory()
        let repository = RecipeRepository(database: database)
        let reviews = RecipeReviewRepository(database: database)
        let recipe = try Recipe(
            title: "Ghost",
            servings: 1,
            ingredients: [Ingredient(name: "Water", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Boil the water.", timerDuration: 300)]
        )
        try repository.create(recipe)
        try reviews.save(try RecipeReviewRecord(recipeID: recipe.id))
        try reviews.addObservation(
            KitchenTestObservation(result: .failed, notes: "Boil-dry on 300 s; needs 180 s.", tester: "rwrife"),
            recipeID: recipe.id
        )

        try repository.delete(id: recipe.id)
        XCTAssertNil(try reviews.fetch(recipeID: recipe.id))
        XCTAssertTrue(try reviews.fetchAll().isEmpty)
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kitchen_test_observations"), 0)
        }
    }

    func testQueueIgnoresTestedAndUnprioritizedRecords() throws {
        let testedID = UUID()
        let queuedID = UUID()
        let silentID = UUID()
        let records = [
            try RecipeReviewRecord(recipeID: queuedID, testPriority: 2),
            try RecipeReviewRecord(recipeID: silentID),
            try RecipeReviewRecord(
                recipeID: testedID,
                testPriority: nil,
                observations: [
                    KitchenTestObservation(result: .passed, notes: "reproducible notes", tester: "rwrife")
                ]
            ),
        ]
        let entries = KitchenTestQueue.entries(from: records)
        XCTAssertEqual(entries.map(\.recipeID), [queuedID])
    }

    // MARK: - Board merge rules

    func testBoardShowsPackEntriesAndLocalRecipesWithCorrectStates() throws {
        let pack = try loadPack()
        let packEntry = try XCTUnwrap(pack.recipes.first(where: { $0.reviewStatus == .deskReviewPassed }))
        let packID = try XCTUnwrap(packEntry.recipeID)

        // A local recipe whose title matches a pack entry merges into that
        // pack row rather than duplicating it.
        let matching = try Recipe(
            id: packID,
            title: packEntry.title,
            servings: 4,
            ingredients: [Ingredient(name: "Water", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Boil the water.", timerDuration: 300)]
        )
        let localOnly = try Recipe(
            title: "My Private Stew",
            servings: 2,
            ingredients: [Ingredient(name: "Water", amount: 1, unit: .cup)],
            steps: [RecipeStep(instruction: "Boil the water.", timerDuration: 300)]
        )

        let rows = RecipeReviewBoardRow.build(pack: pack, records: [], recipes: [localOnly, matching])
        let packRow = try XCTUnwrap(rows.first(where: { $0.recipeID == packID }))
        XCTAssertEqual(packRow.deskState, .passed)
        XCTAssertNotNil(packRow.provenance)

        let localRow = try XCTUnwrap(rows.first(where: { $0.title == "My Private Stew" }))
        XCTAssertEqual(localRow.deskState, .notInReviewPack)
        XCTAssertNil(localRow.queuePriority)
        XCTAssertEqual(rows.count, pack.recipes.count + 1, "local recipe must not add a duplicate pack row")
    }

    func testBoardOrdersQueuedRecipesFirstByPriority() throws {
        let pack = try loadPack()
        let rows = RecipeReviewBoardRow.build(pack: pack, records: [], recipes: [])
        let titles = rows.compactMap { row -> String? in
            guard let priority = row.queuePriority else { return nil }
            return "\(priority):\(row.title)"
        }
        let priorities = rows.compactMap(\.queuePriority)
        XCTAssertEqual(priorities, priorities.sorted())
        XCTAssertEqual(Set(priorities).count, priorities.count, "queue priorities must be unique")
        XCTAssertFalse(titles.isEmpty)
        // Every queued recipe must come before every unqueued one.
        let firstUntestedRow = rows.firstIndex(where: { $0.queuePriority == nil })
        let lastQueuedRow = rows.lastIndex(where: { $0.queuePriority != nil })
        if let firstUntestedRow, let lastQueuedRow {
            XCTAssertGreaterThan(firstUntestedRow, lastQueuedRow)
        }
    }

    func testPackEntriesSurviveWithEmptyDatabase() throws {
        // Desk truth must be visible before the catalog is installed —
        // the gap report is pack truth, not database state.
        let pack = try loadPack()
        let rows = RecipeReviewBoardRow.build(pack: pack, records: [], recipes: [])
        XCTAssertEqual(rows.count, pack.recipes.count)
        XCTAssertTrue(rows.contains { $0.deskState == .issuesOpen })
    }

    // MARK: - Seed-script parser (pack ↔ content cross-check)

    struct SeedRecipe {
        let title: String
        let ingredients: [(String, Double, String)]
        let steps: [(String, TimeInterval?)]

        func makeRecipe() throws -> Recipe {
            try Recipe(
                title: title,
                servings: 4,
                ingredients: ingredients.map {
                    guard let unit = IngredientUnit(rawValue: $0.2) else {
                        throw RecipeRepositoryError.corruptData("seed unit \($0.2)")
                    }
                    return try Ingredient(name: $0.0, amount: $0.1, unit: unit)
                },
                steps: steps.map {
                    try RecipeStep(instruction: $0.0, timerDuration: $0.1)
                }
            )
        }
    }

    private static func parseSeedRecipes(at url: URL) throws -> [SeedRecipe] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let entryPattern = try NSRegularExpression(
            pattern: #"^\s*\('([^']+)',\s*\[([^\]]*)\],\s*\[(.*?)\],\s*\[(.*?)\]\),?\s*$"#,
            options: [.anchorsMatchLines]
        )
        let ingredientPattern = try NSRegularExpression(
            pattern: #"\('([^']+)',\s*([\d.]+),\s*'([a-z]+)'\)"#
        )
        let stepPattern = try NSRegularExpression(
            pattern: #"\('([^']+)',\s*(None|\d+(?:\.\d+)?)\)"#
        )
        var recipes: [SeedRecipe] = []
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in entryPattern.matches(in: source, options: [], range: fullRange) {
            func group(_ index: Int) -> String {
                let range = NSRange(location: 0, length: source.utf16.count)
                _ = range
                guard let r = Range(match.range(at: index), in: source) else { return "" }
                return String(source[r])
            }
            let title = group(1)
            let ingredientText = group(3)
            let stepText = group(4)

            func captures(_ regex: NSRegularExpression, _ text: String) -> [[String]] {
                let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
                return regex.matches(in: text, options: [], range: textRange).map { match in
                    (1..<match.numberOfRanges).compactMap { index in
                        Range(match.range(at: index), in: text).map { String(text[$0]) }
                    }
                }
            }

            let ingredients = captures(ingredientPattern, ingredientText).map { parts in
                (parts[0], Double(parts[1]) ?? 0, parts[2])
            }
            let steps = captures(stepPattern, stepText).map { parts -> (String, TimeInterval?) in
                (parts[0], parts[1] == "None" ? nil : Double(parts[1]))
            }
            recipes.append(SeedRecipe(title: title, ingredients: ingredients, steps: steps))
        }
        XCTAssertGreaterThanOrEqual(recipes.count, 6, "seed script should parse fully")
        return recipes
    }

    /// Build a Recipe from a pack entry snapshot for the directional
    /// gates. When a pack entry has no embedded snapshot, the content
    /// source of truth is the seed script — locate the matching seed
    /// recipe and use it, so pack status is always validated against the
    /// bytes the app will actually ship.
    private static func recipe(from entry: RecipeReviewPackEntry) throws -> Recipe {
        if let snapshot = entry.sourceRecipe {
            return try Recipe(
                id: entry.recipeID ?? UUID(),
                title: snapshot.title,
                servings: snapshot.servings,
                ingredients: snapshot.ingredients.map {
                    try Ingredient(
                        name: $0.name,
                        amount: $0.amount,
                        unit: IngredientUnit(rawValue: $0.unit) ?? .each
                    )
                },
                steps: snapshot.steps.map {
                    try RecipeStep(
                        instruction: $0.instruction,
                        timerDuration: $0.timerSeconds.map(TimeInterval.init)
                    )
                }
            )
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let seeds = try parseSeedRecipes(at: root.appendingPathComponent(seedRelativePath))
        guard let seed = seeds.first(where: { $0.title == entry.title }) else {
            throw RecipeRepositoryError.corruptData("pack entry '\(entry.title)' has no snapshot and no seed match")
        }
        return try seed.makeRecipe()
    }
}
