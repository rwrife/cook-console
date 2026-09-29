import Foundation

/// Actionable guidance for pan sizing, batching, and cooking time adjustments
/// when recipes are scaled away from their tested yield.
struct ScalingLimitsGuidance: Equatable, Sendable {
    let ratio: Double
    let isBakingRecipe: Bool
    let panSizeGuidance: String?
    let batchGuidance: String?
    let cookingTimeGuidance: String?

    var hasGuidance: Bool {
        panSizeGuidance != nil || batchGuidance != nil || cookingTimeGuidance != nil
    }

    static func guidance(for recipe: Recipe, targetServings: Double) -> ScalingLimitsGuidance {
        guard recipe.servings.isFinite, recipe.servings > 0,
              targetServings.isFinite, targetServings > 0
        else {
            return ScalingLimitsGuidance(
                ratio: 1.0,
                isBakingRecipe: false,
                panSizeGuidance: nil,
                batchGuidance: nil,
                cookingTimeGuidance: nil
            )
        }

        let ratio = (targetServings / recipe.servings * 1_000).rounded() / 1_000
        if abs(ratio - 1.0) < 0.001 {
            return ScalingLimitsGuidance(
                ratio: 1.0,
                isBakingRecipe: isBaking(recipe),
                panSizeGuidance: nil,
                batchGuidance: nil,
                cookingTimeGuidance: nil
            )
        }

        let baking = isBaking(recipe)
        let ratioString = ratioFormatted(ratio)
        let originalDuration = primaryTimerDuration(for: recipe)

        let pan: String?
        let batch: String?
        let time: String?

        if baking {
            if ratio >= 1.5 {
                pan = "Baking scaled \(ratioString): bake in two 8-inch or 9-inch pans rather than a single deeper pan so the center bakes evenly."
                batch = ratio >= 2.0
                    ? "Double batch: prepare batter in two separate batches if bowl or mixer capacity is crowded."
                    : nil
                if let originalDuration {
                    let minutes = Int(round(originalDuration / 60))
                    time = "Do not double baking time. Cooking time depends on pan depth; check for doneness around the original \(minutes) min (usually within ±5 minutes)."
                } else {
                    time = "Do not scale baking time linearly. Baking time depends on pan depth, not total volume; keep baking time close to original and check doneness with a tester."
                }
            } else if ratio <= 0.67 {
                pan = "Baking scaled \(ratioString): use a smaller pan (e.g. mini-loaf or 6-inch pan) so batter depth matches the original recipe."
                batch = nil
                if let originalDuration {
                    let minutes = Int(round(originalDuration / 60))
                    time = "Do not cut baking time in half linearly. Check doneness 5–10 minutes earlier than the original \(minutes) min."
                } else {
                    time = "Do not cut baking time in half linearly. Check doneness a few minutes earlier as shallower batter bakes faster."
                }
            } else {
                pan = nil
                batch = nil
                time = nil
            }
        } else {
            // General cooking (skillet, stew, roast)
            if ratio >= 1.5 {
                pan = "Cooking scaled \(ratioString): use a wider skillet or Dutch oven so ingredients sear instead of steaming."
                batch = ratio >= 2.5
                    ? "Batch cooking: cook in multiple batches rather than crowding a single pan."
                    : nil
                time = "Do not scale cooking time linearly (\(ratioString)). Searing time stays similar; allow a few extra minutes for batching or reaching a simmer."
            } else if ratio <= 0.67 {
                pan = "Cooking scaled \(ratioString): use a smaller pan to prevent sauces and liquids from evaporating too quickly."
                batch = nil
                time = "Do not scale cooking time down linearly. Searing and browning take the same time; simmer liquids may reduce faster in a wide pan."
            } else {
                pan = nil
                batch = nil
                time = nil
            }
        }

        return ScalingLimitsGuidance(
            ratio: ratio,
            isBakingRecipe: baking,
            panSizeGuidance: recipe.panSizeGuidance ?? pan,
            batchGuidance: recipe.batchSizeGuidance ?? batch,
            cookingTimeGuidance: recipe.cookingTimeGuidance ?? time
        )
    }

    private static func isBaking(_ recipe: Recipe) -> Bool {
        let bakingKeywords = ["bake", "baking", "cake", "bread", "cookie", "muffin", "pie", "pastry"]
        if recipe.tags.contains(where: { tag in
            bakingKeywords.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) {
            return true
        }
        let titleWords = recipe.title.lowercased()
        if bakingKeywords.contains(where: { titleWords.contains($0) }) {
            return true
        }
        return false
    }

    private static func primaryTimerDuration(for recipe: Recipe) -> TimeInterval? {
        recipe.steps.compactMap(\.timerDuration).first
    }

    private static func ratioFormatted(_ ratio: Double) -> String {
        if abs(ratio - ratio.rounded()) < 0.001 {
            return "\(Int(ratio.rounded()))x"
        }
        return "\(ratio)x"
    }
}
