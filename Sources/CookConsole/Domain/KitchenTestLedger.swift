import Foundation

/// Issue #21: the kitchen-test ledger.
///
/// Three evidence levels are modeled separately and MUST stay separate:
/// * **Desk review** (provenance + revision + editorial audit status) —
///   mechanical/reviewable, CI-checkable.
/// * **Editorial exceptions** — named phrases with written justifications;
///   an exception without a justification is invalid by construction.
/// * **Kitchen testing** — ONLY entered through `KitchenTestObservation`
///   records with reproducible notes. No automated check can ever produce
///   a kitchen-tested claim: `RecipeReviewRecord.kitchenTestStatus` is
///   derived exclusively from observations, and the audit engine has no
///   type path into this file.
enum RecipeReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case deskReviewPassed = "desk_review_passed"
    case deskReviewIssuesOpen = "desk_review_issues_open"
}

enum KitchenTestStatus: String, Codable, CaseIterable, Sendable {
    case notTested = "not_tested"
    case passed
    case failed
}

enum KitchenTestResult: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
}

struct EditorialException: Codable, Equatable, Sendable {
    /// Ingredient vocabulary phrase the exception applies to, lowercase.
    let phrase: String
    /// Written reason this is a false positive (style assumption), never
    /// an empty string — enforced here so JSON can never smuggle one in.
    let justification: String

    enum CodingKeys: String, CodingKey {
        case phrase, justification
    }

    init(phrase: String, justification: String) throws {
        let normalizedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedJustification = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPhrase.isEmpty else {
            throw DomainValidationError.blank(field: "Editorial exception phrase")
        }
        guard !normalizedJustification.isEmpty else {
            throw DomainValidationError.blank(field: "Editorial exception justification")
        }
        self.phrase = normalizedPhrase
        self.justification = normalizedJustification
    }

    /// Custom decode routes through the validating initializer — the
    /// synthesized one would accept a blank justification straight from
    /// JSON, which is exactly the smuggling path this type exists to
    /// close.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            phrase: container.decode(String.self, forKey: .phrase),
            justification: container.decode(String.self, forKey: .justification)
        )
    }
}

struct KitchenTestObservation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let testedAt: Date
    let result: KitchenTestResult
    /// Reproducible notes: what was cooked, deviations, sensory results.
    let notes: String
    let tester: String

    enum CodingKeys: String, CodingKey {
        case id, testedAt, result, notes, tester
    }

    init(
        id: UUID = UUID(),
        testedAt: Date = Date(),
        result: KitchenTestResult,
        notes: String,
        tester: String
    ) throws {
        let normalizedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNotes.isEmpty else {
            throw DomainValidationError.blank(field: "Kitchen-test notes")
        }
        let normalizedTester = tester.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTester.isEmpty else {
            throw DomainValidationError.blank(field: "Kitchen-test tester")
        }
        self.id = id
        self.testedAt = testedAt
        self.result = result
        self.notes = normalizedNotes
        self.tester = normalizedTester
    }

    /// Routes JSON decoding through the validating initializer (a blank
    /// notes/tester field must fail to decode, not slip through).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            testedAt: container.decode(Date.self, forKey: .testedAt),
            result: container.decode(KitchenTestResult.self, forKey: .result),
            notes: container.decode(String.self, forKey: .notes),
            tester: container.decode(String.self, forKey: .tester)
        )
    }
}

struct RecipeReviewRecord: Codable, Equatable, Sendable {
    let recipeID: UUID
    var reviewStatus: RecipeReviewStatus
    /// Where the recipe content came from (author, book, upstream revision).
    var sourceProvenance: String?
    /// Local content revision — bumped whenever recipe content is edited
    /// in a way that requires re-audit (distinct from upstream versions).
    var contentRevision: Int
    var editorialExceptions: [EditorialException]
    /// Physical-test queue rank (1 = test first); nil once tested or when
    /// intentionally unqueued.
    var testPriority: Int?
    var observations: [KitchenTestObservation]

    init(
        recipeID: UUID,
        reviewStatus: RecipeReviewStatus = .unreviewed,
        sourceProvenance: String? = nil,
        contentRevision: Int = 1,
        editorialExceptions: [EditorialException] = [],
        testPriority: Int? = nil,
        observations: [KitchenTestObservation] = []
    ) throws {
        guard contentRevision >= 1 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Content revision")
        }
        if let testPriority {
            guard testPriority >= 1 else {
                throw DomainValidationError.nonPositiveOrNonFinite(field: "Kitchen-test priority")
            }
        }
        self.recipeID = recipeID
        self.reviewStatus = reviewStatus
        self.sourceProvenance = Self.normalized(sourceProvenance)
        self.contentRevision = contentRevision
        self.editorialExceptions = editorialExceptions
        self.testPriority = observations.isEmpty ? testPriority : nil
        self.observations = observations.sorted { $0.testedAt > $1.testedAt }
    }

    /// Derived — there is deliberately NO setter. Kitchen-tested status
    /// exists only if a real observation says so.
    var kitchenTestStatus: KitchenTestStatus {
        guard let latest = observations.first else { return .notTested }
        switch latest.result {
        case .passed: return .passed
        case .failed: return .failed
        }
    }

    /// True when the record claims a physical test result without any
    /// reproducible observation behind it. Always false by construction;
    /// CI asserts this over every shipped ledger as a regression canary.
    var claimsKitchenTestedWithoutEvidence: Bool {
        kitchenTestStatus != .notTested && observations.isEmpty
    }

    /// Exception phrases (lowercase) usable as an audit allow-list.
    var exceptionPhrases: Set<String> {
        Set(editorialExceptions.map(\.phrase))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else { return nil }
        return normalized
    }
}

/// The prioritized physical kitchen-test queue: untested recipes with a
/// deliberate priority, ordered deterministically (priority, then recipe
/// ID). Untested recipes without a priority are reviewed for priority
/// later — they never silently enter the queue.
enum KitchenTestQueue {
    struct Entry: Equatable, Sendable {
        let recipeID: UUID
        let priority: Int
    }

    static func entries(from records: [RecipeReviewRecord]) -> [Entry] {
        records.compactMap { record -> Entry? in
            guard record.kitchenTestStatus == .notTested, let priority = record.testPriority else {
                return nil
            }
            return Entry(recipeID: record.recipeID, priority: priority)
        }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.recipeID.uuidString < rhs.recipeID.uuidString
        }
    }
}

// MARK: - Review pack (curated repo artifact, issue #21)

/// A per-recipe entry in a curated review pack file. The optional
/// `sourceRecipe` lets future packs carry their own content snapshot;
/// the starter-seed pack deliberately omits it — `Tools/
/// seed_screenshot_recipes.py` remains the single source of catalog
/// content truth and CI cross-checks the pack against it.
struct RecipeReviewPackEntry: Codable, Equatable, Sendable {
    struct SourceIngredient: Codable, Equatable, Sendable {
        let name: String
        let amount: Double
        let unit: String
    }

    struct SourceStep: Codable, Equatable, Sendable {
        let instruction: String
        let timerSeconds: Int?
    }

    struct SourceRecipe: Codable, Equatable, Sendable {
        let title: String
        let servings: Double
        let ingredients: [SourceIngredient]
        let steps: [SourceStep]
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source
        case sourceProvenance = "source_provenance"
        case reviewStatus = "review_status"
        case contentRevision = "content_revision"
        case editorialExceptions = "editorial_exceptions"
        case testPriority = "test_priority"
        case observations
        case sourceRecipe = "source_recipe"
    }

    /// Canonical uppercased UUID string, stable across regenerations
    /// (uuid5 of the seed title).
    let id: String
    let title: String
    let source: String
    let sourceProvenance: String?
    let reviewStatus: RecipeReviewStatus
    let contentRevision: Int
    let editorialExceptions: [EditorialException]
    let testPriority: Int?
    let observations: [KitchenTestObservation]
    let sourceRecipe: SourceRecipe?

    var recipeID: UUID? { UUID(uuidString: id) }

    var exceptionPhrases: Set<String> {
        Set(editorialExceptions.map(\.phrase))
    }

    /// Validated record view for repository import. Throws on an invalid
    /// UUID or malformed ledger content so CI can never load a pack that
    /// smuggles unjustified exceptions.
    func makeReviewRecord() throws -> RecipeReviewRecord {
        guard let uuid = recipeID else {
            throw RecipeReviewRepositoryError.invalidData("Pack entry id '\(id)' is not a UUID")
        }
        return try RecipeReviewRecord(
            recipeID: uuid,
            reviewStatus: reviewStatus,
            sourceProvenance: sourceProvenance,
            contentRevision: contentRevision,
            editorialExceptions: editorialExceptions,
            testPriority: testPriority,
            observations: observations
        )
    }
}

struct RecipeReviewPack: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packVersion = "pack_version"
        case recipes
    }

    let schemaVersion: Int
    let packVersion: String
    let recipes: [RecipeReviewPackEntry]

    static func load(from url: URL) throws -> RecipeReviewPack {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(RecipeReviewPack.self, from: data)
        } catch {
            throw RecipeReviewRepositoryError.invalidData("Review pack at \(url.lastPathComponent) is not decodable: \(error)")
        }
    }
}

// MARK: - Board row (merged desk truth + durable physical evidence)

/// One row of the in-app review board. Desk fields come from the curated
/// pack (single source of truth); the kitchen-test fields come ONLY from
/// durable observations. Pure so Linux CI can prove the merge rules.
struct RecipeReviewBoardRow: Equatable, Sendable {
    enum DeskState: String, Sendable {
        case passed
        case issuesOpen
        case notInReviewPack
    }

    let recipeID: UUID
    let title: String
    let deskState: DeskState
    let provenance: String?
    let exceptionCount: Int
    let kitchenTestStatus: KitchenTestStatus
    let observationCount: Int
    let queuePriority: Int?
    /// Physical tests attach to a cookable local recipe (FK to `recipes`);
    /// pack-only desk rows (catalog not installed on this device) cannot
    /// accept observations.
    let existsLocally: Bool

    static func build(
        pack: RecipeReviewPack?,
        records: [RecipeReviewRecord],
        recipes: [Recipe]
    ) -> [RecipeReviewBoardRow] {
        let recordsByID = Dictionary(records.map { ($0.recipeID, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [RecipeReviewBoardRow] = []

        // Pack rows first — desk truth is visible even before/without the
        // matching recipe being installed on this device. When a local
        // recipe matches by UUID or title, the row adopts the LOCAL id:
        // kitchen observations persist against the cookable recipe (FK),
        // while desk fields stay pack truth.
        for entry in pack?.recipes ?? [] {
            guard let packID = entry.recipeID else { continue }
            let localRecipe = recipes.first { $0.id == packID || $0.title == entry.title }
            let rowID = localRecipe?.id ?? packID
            let record = recordsByID[rowID]
            let observations = record?.observations ?? []
            rows.append(RecipeReviewBoardRow(
                recipeID: rowID,
                title: entry.title,
                deskState: entry.reviewStatus == .deskReviewIssuesOpen ? .issuesOpen : .passed,
                provenance: entry.sourceProvenance,
                exceptionCount: entry.editorialExceptions.count,
                kitchenTestStatus: record?.kitchenTestStatus ?? .notTested,
                observationCount: observations.count,
                queuePriority: record?.testPriority
                    ?? (record == nil || record?.kitchenTestStatus == .notTested ? entry.testPriority : nil),
                existsLocally: localRecipe != nil
            ))
        }

        // Local recipes outside the pack (user-created) surface as
        // notInReviewPack so the board never hides coverage gaps.
        for recipe in recipes where pack?.recipes.contains(where: { $0.recipeID == recipe.id || $0.title == recipe.title }) != true {
            let record = recordsByID[recipe.id]
            rows.append(RecipeReviewBoardRow(
                recipeID: recipe.id,
                title: recipe.title,
                deskState: .notInReviewPack,
                provenance: record?.sourceProvenance,
                exceptionCount: record?.editorialExceptions.count ?? 0,
                kitchenTestStatus: record?.kitchenTestStatus ?? .notTested,
                observationCount: record?.observations.count ?? 0,
                queuePriority: record?.testPriority,
                existsLocally: true
            ))
        }

        return sortRows(rows)
    }

    static func sortRows(_ rows: [RecipeReviewBoardRow]) -> [RecipeReviewBoardRow] {
        rows.sorted { lhs, rhs in
            // Queue first (by priority), then remaining by title.
            switch (lhs.queuePriority, rhs.queuePriority) {
            case let (left?, right?):
                if left != right { return left < right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: - Gap report (AC #6: publish remaining manual review/testing work)

/// Deterministic, human-readable gap report over MERGED board rows
/// (pack desk truth + durable observations). CI prints it; the in-app
/// banner renders from it. Pure function over already-merged rows, so
/// the published text can never drift from the ledger it summarizes and
/// a recorded kitchen test immediately leaves the queue.
struct KitchenTestGapSummary: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let title: String
        let reason: String
    }

    let packVersion: String
    let deskPassedCount: Int
    let openDefectCount: Int
    let kitchenTestedCount: Int
    let physicalQueue: [Row]
    let untestedWithoutPriority: [String]

    var isFullyTested: Bool {
        physicalQueue.isEmpty && untestedWithoutPriority.isEmpty
    }

    init(packVersion: String, rows: [RecipeReviewBoardRow]) {
        self.packVersion = packVersion
        deskPassedCount = rows.filter { $0.deskState == .passed }.count
        openDefectCount = rows.filter { $0.deskState == .issuesOpen }.count
        kitchenTestedCount = rows.filter { $0.observationCount > 0 }.count

        var queue: [Row] = []
        var withoutPriority: [String] = []
        for row in rows where row.observationCount == 0 {
            if let priority = row.queuePriority {
                let reason = row.deskState == .issuesOpen
                    ? "open desk-review defect — fix data, then physical test"
                    : "desk-passed, awaiting physical kitchen test"
                queue.append(Row(title: "\(priority): \(row.title)", reason: reason))
            } else {
                withoutPriority.append(row.title)
            }
        }
        // `rows` arrive sorted queue-first by priority (RecipeReviewBoardRow
        // .sortRows); the queue keeps that order.
        physicalQueue = queue
        untestedWithoutPriority = withoutPriority.sorted()
    }

    var markdown: String {
        var lines: [String] = []
        lines.append("# Kitchen-test gap report (pack \(packVersion))")
        lines.append("")
        lines.append("- Desk review passed: \(deskPassedCount)")
        lines.append("- Desk-review defects open: \(openDefectCount)")
        lines.append("- Physical kitchen tests recorded: \(kitchenTestedCount)")
        lines.append("- Remaining in physical queue: \(physicalQueue.count)")
        lines.append("- Untested without a priority: \(untestedWithoutPriority.count)")
        lines.append("")
        lines.append("Automated/desk evidence NEVER substitutes for a physical kitchen test.")
        lines.append("")
        if !physicalQueue.isEmpty {
            lines.append("## Physical test queue (priority order)")
            for (index, row) in physicalQueue.enumerated() {
                lines.append("\(index + 1). \(row.title) — \(row.reason)")
            }
            lines.append("")
        }
        if !untestedWithoutPriority.isEmpty {
            lines.append("## Untested, no priority assigned yet")
            for title in untestedWithoutPriority {
                lines.append("- \(title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
