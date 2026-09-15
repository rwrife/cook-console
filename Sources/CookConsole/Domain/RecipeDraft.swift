import Foundation

struct RecipeDraft {
    var id: UUID
    var title: String
    var servings: String
    var ingredients: [IngredientDraft]
    var steps: [StepDraft]
    var tags: String
    var isFavorite: Bool

    private let locale: Locale

    init(recipe: Recipe?, locale: Locale = .current) {
        self.locale = locale
        id = recipe?.id ?? UUID()
        title = recipe?.title ?? ""
        servings = recipe.map { EditableNumber.string($0.servings, locale: locale) } ?? "1"
        ingredients = recipe?.ingredients.enumerated().map {
            IngredientDraft(position: $0.offset + 1, ingredient: $0.element, locale: locale)
        } ?? [IngredientDraft(position: 1, locale: locale)]
        steps = recipe?.steps.enumerated().map {
            StepDraft(position: $0.offset + 1, step: $0.element, locale: locale)
        } ?? [StepDraft(position: 1, locale: locale)]
        tags = recipe?.tags.joined(separator: ", ") ?? ""
        isFavorite = recipe?.isFavorite ?? false
    }

    mutating func addIngredient() {
        ingredients.append(IngredientDraft(position: ingredients.count + 1, locale: locale))
    }

    mutating func removeIngredient(id: UUID) {
        ingredients.removeAll { $0.id == id }
        renumber()
    }

    mutating func addStep() {
        steps.append(StepDraft(position: steps.count + 1, locale: locale))
    }

    mutating func removeStep(id: UUID) {
        steps.removeAll { $0.id == id }
        renumber()
    }

    func makeRecipe() throws -> Recipe {
        guard let servingsValue = EditableNumber.parse(servings, locale: locale) else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Servings")
        }
        let domainIngredients = try ingredients.map { draft in
            guard let amount = EditableNumber.parse(draft.amount, locale: locale) else {
                throw DomainValidationError.nonPositiveOrNonFinite(field: "Ingredient amount")
            }
            return try Ingredient(
                id: draft.id,
                name: draft.name,
                amount: amount,
                unit: draft.unit
            )
        }
        let domainSteps = try steps.map { draft in
            let timer: TimeInterval?
            if draft.timerMinutes == draft.originalTimerMinutes {
                timer = draft.originalTimerDuration
            } else if draft.timerMinutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                timer = nil
            } else if let minutes = EditableNumber.parse(draft.timerMinutes, locale: locale) {
                timer = minutes * 60
            } else {
                throw DomainValidationError.nonPositiveOrNonFinite(field: "Timer duration")
            }
            return try RecipeStep(
                id: draft.id,
                instruction: draft.instruction,
                timerDuration: timer
            )
        }
        return try Recipe(
            id: id,
            title: title,
            servings: servingsValue,
            ingredients: domainIngredients,
            steps: domainSteps,
            tags: tags.split(separator: ",", omittingEmptySubsequences: false).map(String.init),
            isFavorite: isFavorite
        )
    }

    private mutating func renumber() {
        for index in ingredients.indices { ingredients[index].position = index + 1 }
        for index in steps.indices { steps[index].position = index + 1 }
    }
}

struct IngredientDraft: Identifiable {
    var id: UUID
    var position: Int
    var name: String
    var amount: String
    var unit: IngredientUnit

    init(position: Int, ingredient: Ingredient? = nil, locale: Locale = .current) {
        id = ingredient?.id ?? UUID()
        self.position = position
        name = ingredient?.name ?? ""
        amount = ingredient.map { EditableNumber.string($0.amount, locale: locale) } ?? "1"
        unit = ingredient?.unit ?? .each
    }
}

struct StepDraft: Identifiable {
    var id: UUID
    var position: Int
    var instruction: String
    var timerMinutes: String

    fileprivate let originalTimerDuration: TimeInterval?
    fileprivate let originalTimerMinutes: String

    init(position: Int, step: RecipeStep? = nil, locale: Locale = .current) {
        id = step?.id ?? UUID()
        self.position = position
        instruction = step?.instruction ?? ""
        originalTimerDuration = step?.timerDuration
        originalTimerMinutes = step?.timerDuration.map {
            EditableNumber.string($0 / 60, locale: locale)
        } ?? ""
        timerMinutes = originalTimerMinutes
    }
}

private enum EditableNumber {
    static func string(_ value: Double, locale: Locale) -> String {
        let lossless = String(value)
        guard let separator = locale.decimalSeparator, separator != "." else {
            return lossless
        }
        return lossless.replacingOccurrences(of: ".", with: separator)
    }

    static func parse(_ text: String, locale: Locale) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        if separator != ".", trimmed.contains(".") { return nil }
        return Double(trimmed.replacingOccurrences(of: separator, with: "."))
    }
}
