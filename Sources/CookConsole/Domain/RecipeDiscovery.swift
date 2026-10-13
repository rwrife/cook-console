import Foundation

/// Discovery uses only explicit recipe metadata. A missing duration is unknown,
/// never zero. Dietary tags are user-authored labels, NOT verified safety claims.
struct RecipeDiscoveryFilter: Equatable {
    var text = ""
    var maxMinutes: Int? = nil
    var maxIngredients: Int? = nil
    var ingredient = ""
    var mealType: String? = nil
    var dietaryTag: String? = nil

    static let mealTypes = ["breakfast", "lunch", "dinner", "snack"]
    static let dietaryTags = ["vegetarian", "vegan", "gluten-free", "dairy-free"]

    var activeLabels: [String] {
        var labels: [String] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { labels.append("Search: \(text)") }
        if let maxMinutes { labels.append("\(maxMinutes) min or less") }
        if let maxIngredients { labels.append("\(maxIngredients) ingredients or fewer") }
        if !ingredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { labels.append("Ingredient: \(ingredient)") }
        if let mealType { labels.append("Meal: \(mealType)") }
        if let dietaryTag { labels.append("Tagged: \(dietaryTag)") }
        return labels
    }

    var isActive: Bool { !activeLabels.isEmpty }

    func matches(_ recipe: Recipe) -> Bool {
        let titleQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredientQuery = ingredient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleQuery.isEmpty && !recipe.title.localizedCaseInsensitiveContains(titleQuery) { return false }
        if let maxMinutes, recipe.totalMinutes.map({ $0 <= maxMinutes }) != true { return false }
        // Rule: count every ingredient row, including salt, water, and duplicate names.
        // Recipe validation requires at least one row, so unknown is not possible here.
        if let maxIngredients, recipe.ingredients.count > maxIngredients { return false }
        if !ingredientQuery.isEmpty && !recipe.ingredients.contains(where: {
            $0.name.localizedCaseInsensitiveContains(ingredientQuery)
        }) { return false }
        if let mealType, !recipe.tags.contains(where: { $0.caseInsensitiveCompare(mealType) == .orderedSame }) { return false }
        if let dietaryTag, !recipe.tags.contains(where: { $0.caseInsensitiveCompare(dietaryTag) == .orderedSame }) { return false }
        return true
    }
}
