import Foundation

enum ScalingError: Error, Equatable, LocalizedError, Sendable {
    case invalidAmount
    case invalidRatio
    case invalidTargetServings
    case resultOutOfRange

    var errorDescription: String? {
        switch self {
        case .invalidAmount:
            return "The ingredient amount must be finite and greater than zero."
        case .invalidRatio:
            return "The scale ratio must be finite and greater than zero."
        case .invalidTargetServings:
            return "Target servings must be finite and greater than zero."
        case .resultOutOfRange:
            return "The scaled amount is outside the supported numeric range."
        }
    }
}

enum ScalingEngine {
    static func scaledIngredients(
        for recipe: Recipe,
        targetServings: Double
    ) throws -> [Ingredient] {
        guard targetServings.isFinite, targetServings > 0 else {
            throw ScalingError.invalidTargetServings
        }
        let ratio = targetServings / recipe.servings
        guard ratio.isFinite, ratio > 0 else {
            throw ScalingError.invalidRatio
        }
        return try recipe.ingredients.map { try scaled($0, ratio: ratio) }
    }

    static func scaled(_ ingredient: Ingredient, ratio: Double) throws -> Ingredient {
        let amount = try scaledAmount(ingredient.amount, unit: ingredient.unit, ratio: ratio)
        return try Ingredient(
            id: ingredient.id,
            name: ingredient.name,
            amount: amount,
            unit: ingredient.unit
        )
    }

    static func scaledAmount(
        _ amount: Double,
        unit: IngredientUnit,
        ratio: Double
    ) throws -> Double {
        guard amount.isFinite, amount > 0 else {
            throw ScalingError.invalidAmount
        }
        guard ratio.isFinite, ratio > 0 else {
            throw ScalingError.invalidRatio
        }

        let rawAmount = amount * ratio
        guard rawAmount.isFinite, rawAmount > 0 else {
            throw ScalingError.resultOutOfRange
        }

        let increment = snappingIncrement(for: rawAmount, unit: unit)
        let snapped = (rawAmount / increment).rounded() * increment
        let nonzeroResult = max(increment, snapped)
        let decimalStableResult = (nonzeroResult * 1_000_000_000).rounded() / 1_000_000_000
        guard decimalStableResult.isFinite else {
            throw ScalingError.resultOutOfRange
        }
        return decimalStableResult
    }

    private static func snappingIncrement(
        for amount: Double,
        unit: IngredientUnit
    ) -> Double {
        switch unit {
        case .teaspoon, .tablespoon, .cup:
            if amount < 1 { return 0.125 }
            if amount <= 4 { return 0.25 }
            return 0.5
        case .gram, .milliliter:
            if amount < 1 { return 0.1 }
            if amount < 10 { return 0.5 }
            if amount < 100 { return 1 }
            return 5
        case .kilogram, .liter:
            return amount < 1 ? 0.05 : 0.1
        case .each:
            return 0.5
        case .ounce:
            return 0.25
        case .pound:
            return 0.125
        }
    }
}
