import Foundation

/// One persisted grocery selection: a recipe plus the serving count the
/// shopper wants to buy for. Validation mirrors the domain rules used for
/// recipes (non-blank text, finite positive numbers).
///
/// `checkedKeys` holds the ingredient name keys the shopper has bought for
/// THIS selection. Checks are per (selection, ingredient key) — never one
/// flag per selection — because a merged shopping line (e.g. Olive oil from
/// two recipes) must not mark every other ingredient of those recipes as
/// bought just because the oil line was checked.
struct GrocerySelection: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let recipeID: UUID
    let servings: Double
    let checkedKeys: Set<String>
    let position: Int

    init(
        id: UUID = UUID(),
        recipeID: UUID,
        servings: Double,
        checkedKeys: Set<String> = [],
        position: Int = 0
    ) throws {
        guard servings.isFinite, servings > 0, servings < 1e9 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Selection servings")
        }
        self.id = id
        self.recipeID = recipeID
        self.servings = servings
        self.checkedKeys = checkedKeys
        self.position = position
    }

    func isChecked(forIngredientKey key: String) -> Bool {
        checkedKeys.contains(key)
    }

    /// Replaces the checked-key set, preserving identity, servings, and
    /// position (value semantics keep the model immutable at call sites).
    func withCheckedKeys(_ keys: Set<String>) -> GrocerySelection {
        // init cannot throw here: only checkedKeys changed and it is
        // unvalidated by design (keys are engine-normalized strings).
        // swiftlint:disable:next force_try
        try! GrocerySelection(id: id, recipeID: recipeID, servings: servings, checkedKeys: keys, position: position)
    }

    /// Same identity/servings/checks at a new list position (used right
    /// after INSERT when the store assigns the append slot).
    func withPosition(_ position: Int) -> GrocerySelection {
        // swiftlint:disable:next force_try
        try! GrocerySelection(id: id, recipeID: recipeID, servings: servings, checkedKeys: checkedKeys, position: position)
    }
}

/// One persisted manual shopping line.
struct GroceryManualItem: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isChecked: Bool
    let position: Int

    init(
        id: UUID = UUID(),
        name: String,
        isChecked: Bool = false,
        position: Int = 0
    ) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DomainValidationError.blank(field: "Grocery item name")
        }
        self.id = id
        self.name = normalized
        self.isChecked = isChecked
        self.position = position
    }
}
