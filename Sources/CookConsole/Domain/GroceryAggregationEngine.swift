import Foundation

/// A pure-function aggregation engine: durable selections + manual items +
/// the recipe library in, the complete shopping sheet out. Every rule the
/// acceptance criteria demand (merge accuracy, unit-family separation,
/// provenance, optional/to-taste handling, derived-check stability across
/// recipe edits and serving changes) lives here and is unit-tested without
/// GRDB or UI.
enum GroceryAggregationEngine {
    /// Conservative free-text name classification used only for manual
    /// additions ("2 cans tomatoes"): a leading count followed by a known
    /// unit symbol is a quantity; a trailing "to taste" is a taste dose.
    /// Anything else is a plain named item with no amount.
    struct ManualParse: Equatable, Sendable {
        var name: String
        var amount: Double?
        var unit: IngredientUnit?
        var isTasteDosed: Bool
    }

    private static let unitSymbolMap: [String: IngredientUnit] = [
        "tsp": .teaspoon, "teaspoon": .teaspoon, "teaspoons": .teaspoon,
        "tbsp": .tablespoon, "tablespoon": .tablespoon, "tablespoons": .tablespoon,
        "cup": .cup, "cups": .cup,
        "ml": .milliliter, "milliliter": .milliliter, "milliliters": .milliliter,
        "l": .liter, "liter": .liter, "liters": .liter,
        "g": .gram, "gram": .gram, "grams": .gram,
        "kg": .kilogram, "kilogram": .kilogram, "kilograms": .kilogram,
        "oz": .ounce, "ounce": .ounce, "ounces": .ounce,
        "lb": .pound, "lbs": .pound, "pound": .pound, "pounds": .pound,
        "each": .each,
    ]

    static func parseManualEntry(_ text: String) -> ManualParse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var isTasteDosed = false
        var working = trimmed
        let lowerWorking = working.lowercased()
        if lowerWorking.hasSuffix("to taste") {
            isTasteDosed = true
            working = String(working.dropLast("to taste".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",();-"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Optional leading "amount unit" prefix: first token numeric, second
        // token a known unit symbol. The remainder is the item name.
        var amount: Double?
        var unit: IngredientUnit?
        let tokens = working.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count >= 3,
           let parsedAmount = DecimalParsing.parse(tokens[0]),
           parsedAmount.isFinite, parsedAmount > 0,
           let parsedUnit = unitSymbolMap[tokens[1].lowercased()]
        {
            amount = parsedAmount
            unit = parsedUnit
            working = tokens.dropFirst(2).joined(separator: " ")
        }

        guard !working.isEmpty else { return nil }
        return ManualParse(name: working, amount: amount, unit: unit, isTasteDosed: isTasteDosed)
    }

    /// A name that means "season to preference" — never summed as a quantity.
    static func isTasteDosedName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("to taste")
    }

    /// Whether an ingredient name carries an optional/to-taste qualifier that
    /// the grocery list must surface even though the recipe schema stores no
    /// per-ingredient optional flag.
    static func hasQualifier(_ name: String) -> Bool {
        isTasteDosedName(name)
            || name.localizedCaseInsensitiveContains("optional")
            || name.localizedCaseInsensitiveContains("to serve")
    }

    /// Every merge-key this recipe's ingredients contribute to. Used when a
    /// whole selection is checked (e.g. programmatic tests / future "buy
    /// everything from this recipe" affordance): the flag lands on every
    /// key the recipe actually contributes, never on unrelated recipes.
    static func contributedKeys(for recipe: Recipe) -> Set<String> {
        Set(recipe.ingredients.compactMap {
            mergeBucket(name: $0.name, amount: $0.amount, unit: $0.unit)?.key
        })
    }

    enum UnitFamily {
        case volume
        case mass
        case count
        /// Pieces that can be weighed (cheese, chocolate, produce by weight)
        /// merge `each` amounts into grams only at very small counts, where
        /// "N small things" ≈ "N × 30 g" is a useful shopping estimate.
        case countConvertible
    }

    static func unitFamily(for unit: IngredientUnit) -> UnitFamily {
        switch unit {
        case .teaspoon, .tablespoon, .cup, .milliliter, .liter:
            return .volume
        case .gram, .kilogram, .ounce, .pound:
            return .mass
        case .each:
            return .count
        }
    }

    /// grams per piece, or nil when the item does not convert.
    static func gramsPerEach(forName name: String) -> Double? {
        let key = PantrySuggestionEngine.normalizeIngredientName(name)
        let convertible: Set<String> = [
            "cheese", "parmesan cheese", "cheddar cheese", "mozzarella cheese",
            "chocolate", "dark chocolate", "milk chocolate",
            "apple", "apples", "potato", "potatoes", "sweet potato", "sweet potatoes",
            "onion", "onions", "carrot", "carrots",
            "lemon", "lemons", "lime", "limes",
            "banana", "bananas", "avocado", "avocados",
        ]
        return convertible.contains(key) ? 30.0 : nil
    }

    /// Map an ingredient into its merge bucket. Returns the name key, the
    /// canonical family unit, the amount already converted into that unit,
    /// and whether the item is a taste dose (excluded from summing).
    static func mergeBucket(name: String, amount: Double, unit: IngredientUnit) -> (key: String, familyUnit: IngredientUnit, converted: Double, isTasteDosed: Bool)? {
        let key = PantrySuggestionEngine.normalizeIngredientName(name)
        guard !key.isEmpty else { return nil }
        let isTasteDosed = isTasteDosedName(name)
        switch unit {
        case .each:
            if unitFamily(for: unit) == .count, let grams = gramsPerEach(forName: name) {
                return (key, .gram, amount * grams, isTasteDosed)
            }
            return (key, .each, amount, isTasteDosed)
        case .teaspoon:
            return (key, .teaspoon, amount, isTasteDosed)
        case .tablespoon:
            // Merge into cups only at 1/4-cup granularity or larger; below a
            // quarter cup, spoons stay spoons (nobody shops 1/16 cup of soy
            // sauce — 2 tbsp does not merge into "0.13 cup").
            let cups = amount / 16.0
            if cups >= 0.25 { return (key, .cup, cups, isTasteDosed) }
            return (key, .tablespoon, amount, isTasteDosed)
        case .cup:
            return (key, .cup, amount, isTasteDosed)
        case .milliliter:
            // Same granularity rule metric-side: >= 100 ml rides with
            // liters; tiny doses (5 ml vanilla) stay milliliters.
            let liters = amount / 1000.0
            if liters >= 0.1 { return (key, .liter, liters, isTasteDosed) }
            return (key, .milliliter, amount, isTasteDosed)
        case .liter:
            return (key, .liter, amount, isTasteDosed)
        case .gram:
            return (key, .gram, amount, isTasteDosed)
        case .kilogram:
            // Grams absorb kilograms: grams are the finer shopping unit.
            return (key, .gram, amount * 1000.0, isTasteDosed)
        case .ounce:
            // >= 16 oz rides with pounds; smaller stays ounces.
            let pounds = amount / 16.0
            if pounds >= 1 { return (key, .pound, pounds, isTasteDosed) }
            return (key, .ounce, amount, isTasteDosed)
        case .pound:
            return (key, .pound, amount, isTasteDosed)
        }
    }

    /// The complete aggregation: merges equivalent ingredients across all
    /// selections (scaled per serving via `ScalingEngine` so ingredient
    /// identity survives serving changes — AC: edits/changes predictable),
    /// groups compatible units per name key, separates taste doses, derives
    /// checked state, and orders manual-first.
    static func aggregate(
        selections: [GrocerySelection],
        manualItems: [GroceryManualItem],
        recipes: [Recipe]
    ) -> GroceryListSnapshot {
        let recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })

        // 1. Scaled contributions per selection.
        struct Contribution {
            let key: String
            let familyUnit: IngredientUnit
            let converted: Double
            let displayName: String
            let sourceLabel: String
            let isTasteDosed: Bool
            let hasQualifier: Bool
            let rawAmount: Double
        }
        var contributions: [String: [Contribution]] = [:]
        var selectionKeys: [UUID: Set<String>] = [:]

        for selection in selections {
            guard let recipe = recipesByID[selection.recipeID] else { continue }
            let sourceLabel = "\(recipe.title) × \(KitchenQuantityFormatter.string(selection.servings))"
            var keysForSelection: Set<String> = []
            // Exact per-recipe scaling first (never display-snapped), then
            // merge. ScalingEngine guards ratio validity; a rejected ratio
            // contributes nothing rather than corrupting the list.
            guard let scaled = try? ScalingEngine.scaledIngredients(
                for: recipe,
                targetServings: selection.servings
            ) else { continue }
            for ingredient in scaled {
                guard let bucket = mergeBucket(
                    name: ingredient.name,
                    amount: ingredient.exactAmount,
                    unit: ingredient.unit
                ) else { continue }
                keysForSelection.insert(bucket.key)
                let contribution = Contribution(
                    key: bucket.key,
                    familyUnit: bucket.familyUnit,
                    converted: bucket.converted,
                    displayName: ingredient.name,
                    sourceLabel: sourceLabel,
                    isTasteDosed: bucket.isTasteDosed,
                    // Taste-dose names always contain "to taste", so
                    // hasQualifier already covers them.
                    hasQualifier: hasQualifier(ingredient.name),
                    rawAmount: ingredient.exactAmount
                )
                contributions[bucket.key, default: []].append(contribution)
            }
            selectionKeys[selection.id] = keysForSelection
        }

        // 2. Derived checks: a name key is checked iff EVERY selection that
        //    contributes to it has that key in its checkedKeys set. Removing
        //    a checked selection or editing a recipe therefore cannot
        //    silently flip remaining contributions to checked, and
        //    unchecking one recipe's demand correctly un-checks the merged
        //    line (the ALL rule is evaluated over current contributors only).
        var keyChecked: [String: Bool] = [:]
        for (key, _) in contributions {
            let contributing = selections.filter { selection in
                selectionKeys[selection.id]?.contains(key) ?? false
            }
            keyChecked[key] = !contributing.isEmpty
                && contributing.allSatisfy { $0.isChecked(forIngredientKey: key) }
        }

        // 3. Merge contributions into lines per (name, familyUnit). A single
        //    name can legitimately occupy two buckets (2 tbsp soy sauce stays
        //    spoons while another recipe's 8 tbsp merges into 1/2 cup) —
        //    mixing them into one sum would be a unit error, so each bucket
        //    gets its own line.
        var recipeLines: [GroceryLine] = []
        for (key, group) in contributions {
            let taste = group.filter(\.isTasteDosed)
            let measured = group.filter { !$0.isTasteDosed }
            let isChecked = keyChecked[key] ?? false

            var measuredByUnit: [IngredientUnit: [Contribution]] = [:]
            for contribution in measured {
                measuredByUnit[contribution.familyUnit, default: []].append(contribution)
            }
            for (familyUnit, bucket) in measuredByUnit {
                let total = bucket.reduce(0) { $0 + $1.converted }
                // Representative display name: the alphabetically-first
                // contributor's name (deterministic across runs).
                let displayName = bucket.map(\.displayName)
                    .min { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? key
                let sources = orderedUnique(bucket.map(\.sourceLabel))
                let exact = (total * 1_000_000_000).rounded() / 1_000_000_000
                recipeLines.append(GroceryLine(
                    id: "recipe:\(key):\(familyUnit.rawValue)",
                    name: displayName,
                    normalizedKey: key,
                    exactAmount: exact,
                    displayAmount: displayAmount(for: exact, unit: familyUnit),
                    unit: familyUnit,
                    sourceAmounts: bucket.map(\.rawAmount),
                    sources: sources,
                    hasOptionalContribution: group.contains(where: \.hasQualifier),
                    isTasteDosed: false,
                    isManual: false,
                    isChecked: isChecked
                ))
            }
            if !taste.isEmpty {
                // All taste doses for this name share one no-quantity line.
                let displayName = taste.map(\.displayName)
                    .min { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? key
                recipeLines.append(GroceryLine(
                    id: "recipe:\(key):taste",
                    name: displayName,
                    normalizedKey: key,
                    exactAmount: nil,
                    displayAmount: nil,
                    unit: nil,
                    sourceAmounts: taste.map(\.rawAmount),
                    sources: orderedUnique(taste.map(\.sourceLabel)),
                    hasOptionalContribution: true,
                    isTasteDosed: true,
                    isManual: false,
                    isChecked: isChecked
                ))
            }
        }

        // 4. Manual lines from durable items.
        let manualLines = manualItems.map { item in
            GroceryLine(
                id: "manual:\(item.id.uuidString)",
                name: item.name,
                normalizedKey: PantrySuggestionEngine.normalizeIngredientName(item.name),
                exactAmount: nil,
                displayAmount: nil,
                unit: nil,
                sourceAmounts: [],
                sources: [],
                hasOptionalContribution: false,
                isTasteDosed: false,
                isManual: true,
                isChecked: item.isChecked
            )
        }

        let sortedRecipeLines = recipeLines.sorted { a, b in
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
        return GroceryListSnapshot(
            manualLines: manualLines,
            recipeLines: sortedRecipeLines
        )
    }

    /// Checked flags a selection edit must persist: a recipe-derived line's
    /// check fans out to every selection contributing to its name key — and
    /// ONLY those, so checking "Salt" can never mark an unrelated recipe
    /// (e.g. one with no salt) checked.
    static func checkedSelectionIDs(
        forLineKey key: String,
        selections: [GrocerySelection],
        recipes: [Recipe]
    ) -> [UUID] {
        let recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        return selections.filter { selection in
            guard let recipe = recipesByID[selection.recipeID] else { return false }
            for ingredient in recipe.ingredients {
                if mergeBucket(name: ingredient.name, amount: ingredient.amount, unit: ingredient.unit)?.key == key {
                    return true
                }
            }
            return false
        }.map(\.id)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Same tier policy as `ScalingEngine`'s display snapping, reused so the
    /// grocery list and the cook screen never disagree on a measure.
    static func displayAmount(for exactAmount: Double, unit: IngredientUnit) -> Double {
        let increment: Double
        switch unit {
        case .teaspoon, .tablespoon, .cup:
            if exactAmount < 1 { increment = 0.125 }
            else if exactAmount <= 4 { increment = 0.25 }
            else { increment = 0.5 }
        case .gram, .milliliter:
            if exactAmount < 1 { increment = 0.1 }
            else if exactAmount < 10 { increment = 0.5 }
            else if exactAmount < 100 { increment = 1 }
            else { increment = 5 }
        case .kilogram, .liter:
            increment = exactAmount < 1 ? 0.05 : 0.1
        case .each:
            increment = 0.25
        case .ounce:
            increment = 0.25
        case .pound:
            increment = 0.125
        }
        let snapped = (exactAmount / increment).rounded() * increment
        let minimum: Double
        switch unit {
        case .teaspoon, .tablespoon, .cup, .pound: minimum = 0.125
        case .each, .ounce: minimum = 0.25
        case .gram, .milliliter: minimum = 0.1
        case .kilogram, .liter: minimum = 0.05
        }
        let value = max(minimum, snapped)
        return (value * 1_000_000_000).rounded() / 1_000_000_000
    }
}
