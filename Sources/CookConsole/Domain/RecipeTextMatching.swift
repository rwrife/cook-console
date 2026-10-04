import Foundation

/// Shared deterministic text matching for the editorial recipe audit
/// (issue #21). Both sides of the ingredient cross-check are mechanical:
///
/// * An ingredient is "mentioned" when any vocabulary form of its name
///   appears as a whole word (or adjacent word pair) in any instruction.
/// * An instruction "mentions an ingredient outside the list" when an
///   ingredient-like noun from the curated glossary appears in an
///   instruction but matches no ingredient vocabulary form and is not an
///   editorial exception.
///
/// The rules are deliberately conservative and reviewable — false
/// positives are resolved by the editorial exception list, never by
/// weakening the checks.
enum RecipeTextMatching {
    /// Whole words that cooks expect to be on hand without being listed
    /// (editorial exceptions for the "mentioned but missing" direction).
    /// Adding a word here must be justified as a style assumption, not a
    /// way to hide a real data bug.
    static let editorialExceptions: Set<String> = [
        "salt", "pepper", "water", "ice",
    ]

    /// Curated common cooking-ingredient nouns. Only these words (and
    /// their naive plurals) can trigger the "mentioned in instructions
    /// but missing from the list" finding, so ordinary verbs like "whisk"
    /// or "simmer" are never flagged.
    static let ingredientLikeNouns: Set<String> = [
        // Vegetables / aromatics
        "onion", "garlic", "shallot", "leek", "scallion", "celery",
        "carrot", "potato", "sweet potato", "tomato", "cherry tomato",
        "mushroom", "zucchini", "cucumber", "lettuce", "spinach", "kale",
        "cabbage", "broccoli", "cauliflower", "corn", "pea", "green pea",
        "green bean", "bell pepper", "chili", "chilli", "avocado",
        "asparagus", "eggplant", "ginger", "squash", "parsnip", "radish",
        // Proteins / dairy
        "chicken", "beef", "lamb", "pork", "bacon", "sausage", "turkey",
        "shrimp", "salmon", "tuna", "cod", "trout", "mussel", "scallop",
        "tofu", "tempeh", "seitan", "egg", "cheese", "cheddar", "parmesan",
        "mozzarella", "feta", "goat cheese", "cream", "milk", "butter",
        "yogurt", "cream cheese", "mascarpone",
        // Grains / pantry staples
        "flour", "rice", "pasta", "noodle", "spaghetti", "penne",
        "macaroni", "lasagna", "bread", "breadcrumb", "oat", "oatmeal",
        "quinoa", "couscous", "polenta", "cornmeal", "panko", "tortilla",
        "bean", "black bean", "chickpea", "lentil", "edamame",
        // Herbs / spices
        "basil", "oregano", "thyme", "rosemary", "parsley", "cilantro",
        "coriander", "mint", "dill", "sage", "bay leaf", "chive", "tarragon",
        "cinnamon", "cumin", "paprika", "turmeric", "curry", "nutmeg",
        "clove", "cardamom", "black pepper", "cayenne", "fennel",
        // Fruits / sweeteners
        "apple", "banana", "lemon", "lime", "orange", "strawberry",
        "blueberry", "raspberry", "mango", "peach", "pear", "grape",
        "pineapple", "date", "raisin", "honey", "maple syrup", "sugar",
        "brown sugar", "powdered sugar", "vanilla", "cocoa", "chocolate",
        "jam", "jelly",
        // Condiments / fats / liquids
        "olive oil", "oil", "ghee", "mayonnaise", "mustard", "ketchup",
        "soy sauce", "fish sauce", "vinegar", "balsamic vinegar", "wine",
        "beer", "stock", "broth", "bouillon", "coconut milk", "coconut",
        "tomato paste", "tomato sauce", "salsa", "pesto", "hummus",
        "caper", "anchovy", "olive", "pickle", "mustard seed",
        "sesame", "sesame seed", "soy", "sriracha", "harissa",
        "cornstarch", "baking powder", "baking soda", "yeast", "gelatin",
        // Nuts / seeds
        "almond", "walnut", "pecan", "cashew", "peanut", "pistachio",
        "sunflower seed", "pumpkin seed", "chia", "flaxseed",
    ]

    /// Lowercase word tokens: splits on anything that is not a letter,
    /// strips possessive and trailing apostrophes, drops pure digits.
    static func words(in text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current: [Character] = []
        for character in lowered {
            if character.isLetter {
                current.append(character)
            } else {
                if !current.isEmpty {
                    tokens.append(String(current))
                    current = []
                }
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens.map { token in
            var trimmed = token
            if trimmed.hasSuffix("'s") { trimmed = String(trimmed.dropLast(2)) }
            if trimmed.hasSuffix("'") { trimmed = String(trimmed.dropLast()) }
            return trimmed
        }.filter { !$0.isEmpty }
    }

    /// Adjacent word pairs, used for multi-word ingredient names like
    /// "olive oil" or "bay leaf".
    static func bigrams(in words: [String]) -> [String] {
        guard words.count > 1 else { return [] }
        return (1..<words.count).map { words[$0 - 1] + " " + words[$0] }
    }

    /// All forms of one ingredient name that count as a mention: the
    /// normalized full name plus its first and last words, each with a
    /// naive plural and the simple singularizations we accept.
    static func vocabulary(forIngredientName name: String) -> Set<String> {
        let normalized = name.lowercased()
        var forms: Set<String> = [normalized]
        let parts = normalized
            .split(whereSeparator: { ",/()".contains($0) || $0 == " " })
            .map(String.init)
        if let first = parts.first {
            forms.formUnion(naiveForms(of: first))
            if let last = parts.last, last != first {
                forms.formUnion(naiveForms(of: last))
            }
        }
        return forms
    }

    /// Singular + naive plural variants of one word, tolerating the
    /// regular -s/-es/-ies/-ves inflections.
    static func naiveForms(of word: String) -> Set<String> {
        var forms: Set<String> = [word]
        forms.insert(word + "s")
        forms.insert(word + "es")
        if word.hasSuffix("y"), !word.hasSuffix("ay"), !word.hasSuffix("ey"),
           !word.hasSuffix("oy") {
            forms.insert(String(word.dropLast()) + "ies")
        }
        if word.hasSuffix("f") { forms.insert(String(word.dropLast()) + "ves") }
        if word.hasSuffix("fe") { forms.insert(String(word.dropLast(2)) + "ves") }
        if word.hasSuffix("s"), word.count > 3 { forms.insert(String(word.dropLast())) }
        if word.hasSuffix("es"), word.count > 4 { forms.insert(String(word.dropLast(2))) }
        if word.hasSuffix("ies"), word.count > 4 { forms.insert(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("ves"), word.count > 4 { forms.insert(String(word.dropLast(3)) + "f") }
        return forms
    }

    /// True when any vocabulary form appears in the precomputed token /
    /// bigram match set of a recipe's instructions.
    static func isMentioned(ingredientName: String, matchSet: Set<String>) -> Bool {
        for form in vocabulary(forIngredientName: ingredientName) where matchSet.contains(form) {
            return true
        }
        return false
    }
}
