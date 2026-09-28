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

/// A scaled ingredient keeps the mathematically exact result separate from its
/// kitchen-friendly display recommendation. Scaling always starts from the
/// recipe's original Ingredient, so display rounding can never accumulate.
struct ScaledIngredient: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let exactAmount: Double
    let displayAmount: Double
    let unit: IngredientUnit
    let actionableGuidance: String?

    var wasRoundedForDisplay: Bool {
        abs(exactAmount - displayAmount) > 0.000_000_001
    }
}

enum ScalingEngine {
    static func scaledIngredients(
        for recipe: Recipe,
        targetServings: Double
    ) throws -> [ScaledIngredient] {
        guard targetServings.isFinite, targetServings > 0 else {
            throw ScalingError.invalidTargetServings
        }
        let ratio = targetServings / recipe.servings
        guard ratio.isFinite, ratio > 0 else {
            throw ScalingError.invalidRatio
        }
        return try recipe.ingredients.map { try scaled($0, ratio: ratio) }
    }

    static func scaled(_ ingredient: Ingredient, ratio: Double) throws -> ScaledIngredient {
        guard ingredient.amount.isFinite, ingredient.amount > 0 else {
            throw ScalingError.invalidAmount
        }
        guard ratio.isFinite, ratio > 0 else {
            throw ScalingError.invalidRatio
        }

        let exact = ingredient.amount * ratio
        guard exact.isFinite, exact > 0 else {
            throw ScalingError.resultOutOfRange
        }
        let display = displayAmount(for: exact, unit: ingredient.unit)
        return ScaledIngredient(
            id: ingredient.id,
            name: ingredient.name,
            exactAmount: exact,
            displayAmount: display,
            unit: ingredient.unit,
            actionableGuidance: actionableGuidance(
                name: ingredient.name,
                exactAmount: exact,
                displayAmount: display,
                unit: ingredient.unit
            )
        )
    }

    private static func displayAmount(for exactAmount: Double, unit: IngredientUnit) -> Double {
        let increment = displayIncrement(for: exactAmount, unit: unit)
        let snapped = (exactAmount / increment).rounded() * increment
        let nonzero = max(minimumDisplayAmount(for: unit), snapped)
        return stable(nonzero)
    }

    private static func displayIncrement(for amount: Double, unit: IngredientUnit) -> Double {
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
            return 0.25
        case .ounce:
            return 0.25
        case .pound:
            return 0.125
        }
    }

    private static func minimumDisplayAmount(for unit: IngredientUnit) -> Double {
        switch unit {
        case .teaspoon, .tablespoon, .cup, .pound:
            return 0.125
        case .each, .ounce:
            return 0.25
        case .gram, .milliliter:
            return 0.1
        case .kilogram, .liter:
            return 0.05
        }
    }

    private static func stable(_ value: Double) -> Double {
        (value * 1_000_000_000).rounded() / 1_000_000_000
    }

    private static func actionableGuidance(
        name: String,
        exactAmount: Double,
        displayAmount: Double,
        unit: IngredientUnit
    ) -> String? {
        guard unit == .each,
              abs(displayAmount.rounded() - displayAmount) > 0.000_000_001
        else { return nil }

        let quantity = KitchenQuantityFormatter.string(displayAmount)
        if name.localizedCaseInsensitiveContains("egg") {
            let eggsToBeat = max(1, Int(ceil(displayAmount)))
            let fraction = KitchenQuantityFormatter.string(displayAmount / Double(eggsToBeat))
            let noun = eggsToBeat == 1 ? "egg" : "eggs"
            return "Beat \(eggsToBeat) \(noun) together, then use about \(fraction) of the mixture for \(quantity) eggs."
        }
        let lower = Int(floor(displayAmount))
        let upper = max(1, Int(ceil(displayAmount)))
        let wholeChoice = lower > 0 ? "\(lower) or \(upper) whole" : "1 whole"
        return "Use \(quantity) \(name.lowercased()) when it can be divided; otherwise choose \(wholeChoice) based on the recipe."
    }
}

enum KitchenQuantityFormatter {
    private static let fractions: [(value: Double, text: String)] = [
        (0.125, "1/8"), (0.25, "1/4"), (0.333_333_333, "1/3"),
        (0.375, "3/8"), (0.5, "1/2"), (0.625, "5/8"),
        (0.666_666_667, "2/3"), (0.75, "3/4"), (0.875, "7/8"),
    ]

    static func string(_ value: Double) -> String {
        let whole = Int(floor(value + 0.000_000_001))
        let remainder = value - Double(whole)
        if abs(remainder) < 0.000_001 { return String(whole) }
        if let fraction = fractions.min(by: {
            abs($0.value - remainder) < abs($1.value - remainder)
        }), abs(fraction.value - remainder) < 0.02 {
            return whole == 0 ? fraction.text : "\(whole) \(fraction.text)"
        }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
