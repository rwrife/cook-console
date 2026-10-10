import Foundation
import GRDB

/// Compiled into the app bundle. These two real recipes are separate from the
/// six screenshot fixtures, which have never been installed on user devices.
struct StarterCookbookPack: Equatable, Sendable {
    let version: Int
    let recipes: [Recipe]

    static func bundled() throws -> Self {
        func id(_ suffix: String) -> UUID { UUID(uuidString: "25000000-0000-0000-0000-" + suffix)! }
        return try Self(version: 1, recipes: [
            Recipe(id: id("000000000001"), title: "Simple Stovetop Oats", servings: 1,
                ingredients: [
                    Ingredient(id: id("000000000101"), name: "Rolled oats", amount: 0.5, unit: .cup),
                    Ingredient(id: id("000000000102"), name: "Water", amount: 1, unit: .cup),
                    Ingredient(id: id("000000000103"), name: "Salt", amount: 0.125, unit: .teaspoon),
                ], steps: [
                    RecipeStep(id: id("000000000201"), instruction: "Combine oats, water, and salt in a small saucepan. Bring to a gentle simmer over medium heat."),
                    RecipeStep(id: id("000000000202"), instruction: "Reduce heat to low. Simmer for about 5 minutes, stirring often, until the oats are tender and creamy. Add a little water if too thick; serve warm.", timerDuration: 300),
                ], tags: ["breakfast", "starter"], panSizeGuidance: "Use a small saucepan."),
            Recipe(id: id("000000000002"), title: "Lemon Cucumber Chickpeas", servings: 2,
                ingredients: [
                    Ingredient(id: id("000000000104"), name: "Canned chickpeas, drained and rinsed", amount: 200, unit: .gram),
                    Ingredient(id: id("000000000105"), name: "Cucumber, diced", amount: 100, unit: .gram),
                    Ingredient(id: id("000000000106"), name: "Lemon juice", amount: 1, unit: .tablespoon),
                    Ingredient(id: id("000000000107"), name: "Olive oil", amount: 1, unit: .tablespoon),
                ], steps: [
                    RecipeStep(id: id("000000000203"), instruction: "Whisk the lemon juice and olive oil in a medium bowl."),
                    RecipeStep(id: id("000000000204"), instruction: "Add the drained chickpeas and diced cucumber. Toss until coated and serve. Refrigerate leftovers promptly."),
                ], tags: ["lunch", "starter"]),
        ])
    }

    func validate() throws {
        guard version > 0, !recipes.isEmpty else { throw StarterCookbookError.invalidPack }
        var ids = Set<UUID>()
        for recipe in recipes {
            for id in [recipe.id] + recipe.ingredients.map(\.id) + recipe.steps.map(\.id) {
                guard ids.insert(id).inserted else { throw StarterCookbookError.invalidPack }
            }
        }
    }
}

enum StarterCookbookAction: String, Sendable {
    case add = "Add starter recipe"
    case update = "Update starter content"
    case unchanged = "Already current"
    case keepEdited = "Conflict: keep your edited recipe"
    case keepArchived = "Keep archived or removed"
    case keepUntracked = "Conflict: keep recipe without starter provenance"
    case blockedActiveCook = "Conflict: finish cooking and stop timers before updating"
}

struct StarterCookbookReview: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        let proposed: Recipe
        let current: Recipe?
        let action: StarterCookbookAction
        var id: UUID { proposed.id }
    }
    let pack: StarterCookbookPack
    let entries: [Entry]
    var canAccept: Bool { !entries.contains { $0.action == .blockedActiveCook } }
}

enum StarterCookbookError: Error, LocalizedError {
    case invalidPack, staleReview, activeCook
    var errorDescription: String? {
        switch self {
        case .invalidPack: "The bundled starter pack or its saved provenance is invalid."
        case .staleReview: "Recipes changed since review. Review the starter update again."
        case .activeCook: "Finish the active cook and stop its timers, then review again, or skip this version."
        }
    }
}

final class StarterCookbookService {
    static let acceptedKey = "starter.cookbook.accepted"
    static let skippedKey = "starter.cookbook.skipped"
    private static let baselinePrefix = "starter.cookbook.baseline."
    private static let excludedPrefix = "starter.cookbook.excluded."
    private let repository: RecipeRepository

    init(repository: RecipeRepository) { self.repository = repository }

    /// A read-only offer; merely launching or reviewing never installs recipes.
    func review(_ pack: StarterCookbookPack) throws -> StarterCookbookReview? {
        try pack.validate()
        return try repository.database.read { db in try review(pack, in: db) }
    }

    func skip(_ review: StarterCookbookReview) throws {
        try review.pack.validate()
        try repository.database.write { db in
            let previous = try version(Self.skippedKey, in: db)
            try put(Self.skippedKey, String(max(previous, review.pack.version)), in: db)
        }
    }

    func accept(_ review: StarterCookbookReview) throws {
        try review.pack.validate()
        try repository.database.write { db in
            if try version(Self.acceptedKey, in: db) >= review.pack.version { return }
            guard let fresh = try self.review(review.pack, in: db), fresh == review else {
                throw StarterCookbookError.staleReview
            }
            guard fresh.canAccept else { throw StarterCookbookError.activeCook }
            for entry in fresh.entries {
                switch entry.action {
                case .add:
                    try repository.insert(entry.proposed, into: db)
                case .update:
                    var stored = Self.content(entry.proposed)
                    stored.isFavorite = entry.current?.isFavorite ?? false
                    try repository.update(DataTransferService.decodedRecipe(stored), in: db)
                case .keepUntracked:
                    // An identity collision is never silently adopted, even after purge.
                    try put(Self.excludedPrefix + entry.id.uuidString, "1", in: db)
                case .keepArchived:
                    if try metadata(Self.baselinePrefix + entry.id.uuidString, in: db) == nil {
                        try put(Self.excludedPrefix + entry.id.uuidString, "1", in: db)
                    }
                case .keepEdited, .unchanged, .blockedActiveCook: break
                }
                if [.add, .update, .unchanged].contains(entry.action) {
                    let data = try JSONEncoder().encode(Self.content(entry.proposed))
                    try put(Self.baselinePrefix + entry.id.uuidString, String(decoding: data, as: UTF8.self), in: db)
                }
            }
            try put(Self.acceptedKey, String(review.pack.version), in: db)
        }
    }

    private func review(_ pack: StarterCookbookPack, in db: Database) throws -> StarterCookbookReview? {
        let decidedVersion = max(try version(Self.acceptedKey, in: db), try version(Self.skippedKey, in: db))
        guard pack.version > decidedVersion else { return nil }
        let entries = try pack.recipes.map { proposed -> StarterCookbookReview.Entry in
            let id = proposed.id.uuidString
            let baselineJSON = try metadata(Self.baselinePrefix + id, in: db)
            let current = try repository.fetchRecipe(id: proposed.id, from: db, includeDeleted: true)
            let archived = try Bool.fetchOne(db, sql: "SELECT deleted_at IS NOT NULL FROM recipes WHERE id = ?", arguments: [id]) ?? false
            let excluded = try metadata(Self.excludedPrefix + id, in: db) != nil
            let action: StarterCookbookAction
            if archived || (current == nil && (baselineJSON != nil || excluded)) {
                action = .keepArchived
            } else if excluded || (baselineJSON == nil && current != nil) {
                action = .keepUntracked
            } else if let current, let baselineJSON {
                let baseline = try Self.baseline(baselineJSON, id: proposed.id)
                if Self.content(current) != baseline {
                    action = .keepEdited
                } else if Self.content(proposed) == baseline {
                    action = .unchanged
                } else {
                    let active = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM cook_sessions WHERE recipe_id = ? AND status = 'active')
                            OR EXISTS(SELECT 1 FROM cook_timers WHERE recipe_id = ? AND status IN ('running', 'paused'))
                        """, arguments: [id, id]) ?? false
                    action = active ? .blockedActiveCook : .update
                }
            } else {
                action = .add
            }
            return StarterCookbookReview.Entry(proposed: proposed, current: current, action: action)
        }
        return StarterCookbookReview(pack: pack, entries: entries)
    }

    private func metadata(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [key])
    }

    private func version(_ key: String, in db: Database) throws -> Int {
        guard let value = try metadata(key, in: db) else { return 0 }
        guard let number = Int(value), number >= 0 else { throw StarterCookbookError.invalidPack }
        return number
    }

    private func put(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO app_metadata (key, value) VALUES (?, ?)", arguments: [key, value])
    }

    private static func content(_ recipe: Recipe) -> BackupDocument.StoredRecipe {
        BackupDocument.StoredRecipe(id: recipe.id, title: recipe.title, servings: recipe.servings,
            isFavorite: false, tags: recipe.tags,
            ingredients: recipe.ingredients.map { .init(id: $0.id, name: $0.name, amount: $0.amount, unit: $0.unit.rawValue) },
            steps: recipe.steps.map { .init(id: $0.id, instruction: $0.instruction, timerDuration: $0.timerDuration) },
            panSizeGuidance: recipe.panSizeGuidance, batchSizeGuidance: recipe.batchSizeGuidance,
            cookingTimeGuidance: recipe.cookingTimeGuidance)
    }

    private static func baseline(_ json: String, id: UUID) throws -> BackupDocument.StoredRecipe {
        let stored = try JSONDecoder().decode(BackupDocument.StoredRecipe.self, from: Data(json.utf8))
        guard stored.id == id, !stored.isFavorite, stored.deletedAt == nil else { throw StarterCookbookError.invalidPack }
        // Validate decoded values through the existing backup/domain boundary.
        try DataTransferService.validateSemantics(of: BackupDocument(
            header: .init(schemaVersion: 1, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "starter"),
            recipes: [stored], sessions: [], timers: [], timerEvents: []))
        return stored
    }

    static func validateMetadata(_ values: [String: String]) throws {
        for (key, value) in values {
            if key == acceptedKey || key == skippedKey {
                guard let number = Int(value), number >= 0 else { throw StarterCookbookError.invalidPack }
            } else if key.hasPrefix(baselinePrefix), let id = UUID(uuidString: String(key.dropFirst(baselinePrefix.count))) {
                _ = try baseline(value, id: id)
            } else if key.hasPrefix(excludedPrefix), UUID(uuidString: String(key.dropFirst(excludedPrefix.count))) != nil, value == "1" {
                continue
            } else {
                throw StarterCookbookError.invalidPack
            }
        }
    }
}
