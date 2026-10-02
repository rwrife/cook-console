import Foundation

/// One visible shopping line (issue #20). Two flavors share one type:
/// - A recipe-derived line has a non-empty `sources` (full provenance).
///   Its checked state is DERIVED from the checked selections of its
///   contributing recipes (see `GroceryAggregation.reconcileChecks`), so
///   adding/removing a selection or changing servings can never "lose" a
///   check unexpectedly — the check always reflects the selections.
/// - A manual line has empty `sources` and owns its persisted check flag.
///
/// `exactAmount` is the mathematically summed amount; `displayAmount` is the
/// kitchen-snapped recommendation (same tier policy as serving scaling).
struct GroceryLine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let normalizedKey: String
    let exactAmount: Double?
    let displayAmount: Double?
    let unit: IngredientUnit?
    /// Raw scaled amounts before merging — one per contributing recipe line.
    let sourceAmounts: [Double]
    /// "Recipe title × servings" provenance labels (deduplicated, ordered).
    let sources: [String]
    let hasOptionalContribution: Bool
    /// "to taste"-style items keep no quantity and are kept separate.
    let isTasteDosed: Bool
    let isManual: Bool
    /// Manual lines: the persisted flag. Recipe lines: the derived state.
    let isChecked: Bool

    var showsAmount: Bool {
        exactAmount != nil && !isTasteDosed
    }
}

/// The full grocery sheet: manual lines first (entry point stays on screen),
/// then recipe-derived lines merged, grouped, and sorted.
struct GroceryListSnapshot: Equatable, Sendable {
    let manualLines: [GroceryLine]
    let recipeLines: [GroceryLine]

    var allLines: [GroceryLine] { manualLines + recipeLines }

    var checkedCount: Int { allLines.filter(\.isChecked).count }
    var totalCount: Int { allLines.count }
    var uncheckedCount: Int { totalCount - checkedCount }
}

/// Plain-text rendering for the share sheet. Provenance and the
/// optional/to-taste qualifiers are preserved in the text itself, so the
/// shared list is complete without the app.
enum GroceryListFormatter {
    static func plainText(_ snapshot: GroceryListSnapshot) -> String {
        var lines: [String] = ["COOK CONSOLE GROCERY LIST"]
        if snapshot.totalCount == 0 {
            lines.append("(empty)")
            return lines.joined(separator: "\n")
        }
        let dateStamp = Date().formatted(date: .abbreviated, time: .omitted)
        lines.append("Generated \(dateStamp) — \(snapshot.uncheckedCount) to buy, \(snapshot.checkedCount) checked off")
        lines.append("")

        func body(_ line: GroceryLine) -> String {
            var text: String
            if line.showsAmount, let amount = line.displayAmount, let unit = line.unit {
                text = "\(KitchenQuantityFormatter.string(amount)) \(unit.symbol) \(line.name)"
            } else {
                text = line.name
            }
            var qualifiers: [String] = []
            if line.isTasteDosed { qualifiers.append("to taste") }
            if line.hasOptionalContribution && !line.isTasteDosed {
                qualifiers.append("some recipes optional")
            }
            if !qualifiers.isEmpty { text += " (\(qualifiers.joined(separator: ", ")))" }
            if line.isChecked { text += " [x]" } else { text += " [ ]" }
            if !line.sources.isEmpty { text += " — for: \(line.sources.joined(separator: "; "))" }
            return text
        }

        if !snapshot.manualLines.isEmpty {
            lines.append("MANUAL ITEMS")
            lines.append(contentsOf: snapshot.manualLines.map(body))
            lines.append("")
        }
        if !snapshot.recipeLines.isEmpty {
            lines.append("FROM RECIPES")
            lines.append(contentsOf: snapshot.recipeLines.map(body))
        }
        return lines.joined(separator: "\n")
    }
}
