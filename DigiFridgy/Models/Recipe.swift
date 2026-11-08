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
    /// Higher-resolution photo for the detail screen, when the source has one.
    var largeImageURL: String?
    var sourceURL: String
    var sourceName: String?
    var ingredients: [RecipeIngredient]
    var calories: Double?
    var servings: Double?
    var totalTimeMinutes: Double?
    /// Edamam tags, lowercased as Edamam returns them ("lunch/dinner", "main course", "italian").
    /// Optional so older cached and saved recipes still decode.
    var mealTypes: [String]?
    var dishTypes: [String]?
    var cuisineTypes: [String]?
    /// "Vegetarian", "Gluten-Free", "High-Protein"…
    var healthLabels: [String]?
    var dietLabels: [String]?

    var caloriesPerServing: Double? {
        guard let calories, calories > 0 else { return nil }
        guard let servings, servings > 0 else { return calories }
        return calories / servings
    }

    /// Health and diet labels, lowercased, for filter matching.
    var allLabels: Set<String> {
        Set(((healthLabels ?? []) + (dietLabels ?? [])).map { $0.lowercased() })
    }
}

/// A fridge item that a recipe uses.
nonisolated struct RecipeMatch: Hashable, Sendable {
    var itemName: String
    var daysUntilExpiry: Int
    /// Whether the item's expiry is an estimate (labels then say "Est.").
    var expiryIsEstimated: Bool = true

    var isExpiringSoon: Bool { daysUntilExpiry <= 3 }

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

    var expiringCount: Int { uses.filter(\.isExpiringSoon).count }
}
