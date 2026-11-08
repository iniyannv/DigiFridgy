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
}

nonisolated struct ScoredRecipe: Identifiable, Hashable, Sendable {
    var recipe: Recipe
    var score: Int
    var uses: [RecipeMatch]
    var missing: [String]
    var id: String { recipe.id }
}
