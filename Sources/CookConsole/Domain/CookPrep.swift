import Foundation

struct CookPrep: Codable, Equatable, Sendable {
    var servings: Double
    var checkedIngredientIDs: Set<UUID>
    var equipment: String
    var swapped: Bool

    init(
        servings: Double = 1,
        checkedIngredientIDs: Set<UUID> = [],
        equipment: String = "",
        swapped: Bool = false
    ) throws {
        guard servings.isFinite, servings > 0 else {
            throw DomainValidationError.nonPositiveOrNonFinite(field: "Servings")
        }
        self.servings = servings
        self.checkedIngredientIDs = checkedIngredientIDs
        self.equipment = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        self.swapped = swapped
    }
}
