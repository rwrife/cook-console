import Foundation

enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case blank(field: String)
    case nonPositiveOrNonFinite(field: String)
    case empty(field: String)

    var errorDescription: String? {
        switch self {
        case let .blank(field):
            return "\(field) must not be blank."
        case let .nonPositiveOrNonFinite(field):
            return "\(field) must be a finite number greater than zero."
        case let .empty(field):
            return "\(field) must contain at least one item."
        }
    }
}

enum IngredientUnit: String, CaseIterable, Hashable, Sendable {
    case each
    case teaspoon
    case tablespoon
    case cup
    case milliliter
    case liter
    case gram
    case kilogram
    case ounce
    case pound

    var symbol: String {
        switch self {
        case .each: "each"
        case .teaspoon: "tsp"
        case .tablespoon: "tbsp"
        case .cup: "cup"
        case .milliliter: "mL"
        case .liter: "L"
        case .gram: "g"
        case .kilogram: "kg"
        case .ounce: "oz"
        case .pound: "lb"
        }
    }
}

struct Ingredient: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let amount: Double
    let unit: IngredientUnit

    init(
        id: UUID = UUID(),
        name: String,
        amount: Double,
        unit: IngredientUnit
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw DomainValidationError.blank(field: "Ingredient name")
        }
        guard amount.isFinite, amount > 0 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Ingredient amount")
        }

        self.id = id
        self.name = normalizedName
        self.amount = amount
        self.unit = unit
    }
}

struct RecipeStep: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let instruction: String
    let timerDuration: TimeInterval?

    init(
        id: UUID = UUID(),
        instruction: String,
        timerDuration: TimeInterval? = nil
    ) throws {
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInstruction.isEmpty else {
            throw DomainValidationError.blank(field: "Step instruction")
        }
        if let timerDuration {
            guard timerDuration.isFinite, timerDuration > 0 else {
                throw DomainValidationError.nonPositiveOrNonFinite(field: "Timer duration")
            }
        }

        self.id = id
        self.instruction = normalizedInstruction
        self.timerDuration = timerDuration
    }
}

struct Recipe: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let servings: Double
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let tags: [String]
    let isFavorite: Bool

    init(
        id: UUID = UUID(),
        title: String,
        servings: Double,
        ingredients: [Ingredient],
        steps: [RecipeStep],
        tags: [String] = [],
        isFavorite: Bool = false
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw DomainValidationError.blank(field: "Recipe title")
        }
        guard servings.isFinite, servings > 0 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Servings")
        }
        guard !ingredients.isEmpty else {
            throw DomainValidationError.empty(field: "Ingredients")
        }
        guard !steps.isEmpty else {
            throw DomainValidationError.empty(field: "Steps")
        }

        self.id = id
        self.title = normalizedTitle
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.tags = Self.normalizedTags(tags)
        self.isFavorite = isFavorite
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            guard seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }
}
