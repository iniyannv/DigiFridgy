import Foundation

nonisolated struct RecipeIngredient: Codable, Hashable, Sendable {
    var text: String
    /// Generic food name, e.g. "spinach".
    var food: String
}

nonisolated struct Recipe: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var imageURL: String?
    var sourceURL: String
    var sourceName: String?
    var ingredients: [RecipeIngredient]
    var calories: Double?
    var servings: Double?
    var totalTimeMinutes: Double?
}

/// A fridge item that a recipe uses.
nonisolated struct RecipeMatch: Hashable, Sendable {
    var itemName: String
    var daysUntilExpiry: Int
    /// Whether the item's expiry is an estimate (labels then say "Est.").
    var expiryIsEstimated: Bool = true

    /// "Est. exp. in 2d" / "Exp. today", matching `FridgeItem.expiryLabel`.
    var expiryLabel: String {
        let text: String
        switch daysUntilExpiry {
        case ..<0: text = "expired"
        case 0: text = "exp. today"
        case 1: text = "exp. tomorrow"
        default: text = "exp. in \(daysUntilExpiry)d"
        }
        return expiryIsEstimated ? "Est. " + text : text.prefix(1).uppercased() + text.dropFirst()
    }
}

nonisolated struct ScoredRecipe: Identifiable, Hashable, Sendable {
    var recipe: Recipe
    var score: Int
    var uses: [RecipeMatch]
    var missing: [String]
    var id: String { recipe.id }
}
