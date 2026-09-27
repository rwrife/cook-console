import Foundation

enum PantryItemKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case onHand = "on_hand"
    case staple = "staple"
}

struct PantryItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: PantryItemKind
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: PantryItemKind,
        createdAt: Date = Date()
    ) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DomainValidationError.blank(field: "Pantry item name")
        }
        self.id = id
        self.name = normalized
        self.kind = kind
        self.createdAt = createdAt
    }
}

struct RecipePantrySuggestion: Identifiable, Equatable, Sendable {
    var id: UUID { recipe.id }
    let recipe: Recipe
    let matchedIngredientNames: [String]
    let stapleIngredientNames: [String]
    let missingIngredientNames: [String]
    let coverage: Double
    let isCompleteMatch: Bool

    init(
        recipe: Recipe,
        matchedIngredientNames: [String],
        stapleIngredientNames: [String],
        missingIngredientNames: [String]
    ) {
        self.recipe = recipe
        self.matchedIngredientNames = matchedIngredientNames
        self.stapleIngredientNames = stapleIngredientNames
        self.missingIngredientNames = missingIngredientNames
        let total = recipe.ingredients.count
        if total == 0 {
            self.coverage = 1.0
            self.isCompleteMatch = true
        } else {
            let availableCount = matchedIngredientNames.count + stapleIngredientNames.count
            self.coverage = Double(availableCount) / Double(total)
            self.isCompleteMatch = missingIngredientNames.isEmpty
        }
    }
}

enum PantrySuggestionEngine {
    static let quantityDisclaimer =
        "Name matches do not confirm that you have enough quantity. Check amounts before cooking."

    static let defaultStaples: [String] = [
        "Salt",
        "Black pepper",
        "Water",
        "Olive oil",
    ]

    static func rank(
        recipes: [Recipe],
        pantryNames: [String],
        stapleNames: [String]
    ) -> [RecipePantrySuggestion] {
        let normalizedPantry = Set(pantryNames.map(normalizeIngredientName))
        let normalizedStaples = Set(stapleNames.map(normalizeIngredientName))

        let suggestions: [RecipePantrySuggestion] = recipes.map { recipe in
            var matched: [String] = []
            var staples: [String] = []
            var missing: [String] = []

            for ingredient in recipe.ingredients {
                let key = normalizeIngredientName(ingredient.name)
                if normalizedPantry.contains(key) {
                    matched.append(ingredient.name)
                } else if normalizedStaples.contains(key) {
                    staples.append(ingredient.name)
                } else {
                    missing.append(ingredient.name)
                }
            }

            return RecipePantrySuggestion(
                recipe: recipe,
                matchedIngredientNames: matched,
                stapleIngredientNames: staples,
                missingIngredientNames: missing
            )
        }

        return suggestions.sorted { a, b in
            if a.isCompleteMatch != b.isCompleteMatch {
                return a.isCompleteMatch && !b.isCompleteMatch
            }
            if abs(a.coverage - b.coverage) > 0.0001 {
                return a.coverage > b.coverage
            }
            if a.missingIngredientNames.count != b.missingIngredientNames.count {
                return a.missingIngredientNames.count < b.missingIngredientNames.count
            }
            if a.matchedIngredientNames.count != b.matchedIngredientNames.count {
                return a.matchedIngredientNames.count > b.matchedIngredientNames.count
            }
            if a.recipe.isFavorite != b.recipe.isFavorite {
                return a.recipe.isFavorite && !b.recipe.isFavorite
            }
            return a.recipe.title.localizedCaseInsensitiveCompare(b.recipe.title) == .orderedAscending
        }
    }

    /// Conservative name normalization: case + whitespace + surrounding
    /// punctuation, then a strict alias table of names that are ordinarily
    /// the SAME ingredient (chickpeas/garbanzo beans, scallions/green
    /// onions). Preparation and form words ("fresh", "dried", "ground",
    /// "smoked") are deliberately RETAINED — "dried basil" must never
    /// silently satisfy a recipe's "fresh basil". Anything not in the alias
    /// table matches only by its own normalized name; the engine never
    /// treats one ingredient as a substitution for another.
    static func normalizeIngredientName(_ name: String) -> String {
        var lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lower = lower
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let conservativeAliases: [String: String] = [
            "chickpea": "garbanzo beans",
            "chickpeas": "garbanzo beans",
            "garbanzo bean": "garbanzo beans",
            "garbanzo beans": "garbanzo beans",
            "scallion": "green onions",
            "scallions": "green onions",
            "green onion": "green onions",
            "green onions": "green onions",
            "spring onion": "green onions",
            "spring onions": "green onions",
            "cilantro": "coriander leaves",
            "coriander leaves": "coriander leaves",
            "aubergine": "eggplant",
            "eggplant": "eggplant",
            "courgette": "zucchini",
            "zucchini": "zucchini",
            "sweet pepper": "bell pepper",
            "capsicum": "bell pepper",
            "shrimp": "prawns",
            "prawn": "prawns",
            "prawns": "prawns",
            "confectioners sugar": "powdered sugar",
            "icing sugar": "powdered sugar",
            "powdered sugar": "powdered sugar",
            "table salt": "salt",
        ]

        return conservativeAliases[lower] ?? lower
    }
}
