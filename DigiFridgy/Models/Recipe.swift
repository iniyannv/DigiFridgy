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
    /// Set when the recipe was adapted to a diet filter (meat swapped for tofu, and so on).
    var swaps: [IngredientSwap]?

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

// MARK: - Difficulty

/// How hard a recipe is from its total time and how many ingredients it needs (pantry basics don't count).
/// Same rule as the backend's `recipes.difficulty`, so iMessage and the app agree.
nonisolated enum RecipeDifficulty: Int, CaseIterable, Comparable, Sendable {
    case easy, medium, hard

    init(minutes: Double?, ingredientCount: Int) {
        let time = minutes.map { $0 <= 20 ? 0 : $0 <= 45 ? 1 : 2 } ?? 1
        let size = ingredientCount <= 6 ? 0 : ingredientCount <= 11 ? 1 : 2
        self = RecipeDifficulty(rawValue: min(2, max(0, time + size - 1))) ?? .medium
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }
}

extension RecipeDifficulty {
    var tone: Tone {
        switch self {
        case .easy: .success
        case .medium: .warning
        case .hard: .danger
        }
    }
}

extension Recipe {
    /// Cooking time to show: the source's, else an estimate from how many ingredients it needs.
    nonisolated var displayMinutes: Int {
        if let totalTimeMinutes { return Int(totalTimeMinutes.rounded()) }
        let estimate = 10 + 4 * max(realIngredientCount, 3)
        return Int((Double(estimate) / 5).rounded()) * 5
    }

    nonisolated var isTimeEstimated: Bool { totalTimeMinutes == nil }

    /// Calories per serving to show: the source's, else a rough estimate from the ingredient count.
    nonisolated var displayCalories: Int {
        if let caloriesPerServing { return Int(caloriesPerServing.rounded()) }
        return max(150, realIngredientCount * 80) / 10 * 10
    }

    nonisolated var isCaloriesEstimated: Bool { caloriesPerServing == nil }

    /// "25 min" or "~25 min" when estimated.
    nonisolated var timeText: String { (isTimeEstimated ? "~" : "") + "\(displayMinutes) min" }
    /// "420 kcal" or "~420 kcal" when estimated.
    nonisolated var caloriesText: String { (isCaloriesEstimated ? "~" : "") + "\(displayCalories) kcal" }

    /// Ingredients you'd actually gather (salt, oil and other pantry basics left out).
    nonisolated var realIngredientCount: Int {
        Set(ingredients.map { $0.food.lowercased().trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty && !RecipeScorer.pantryStaples.contains($0) }.count
    }

    nonisolated var difficulty: RecipeDifficulty {
        RecipeDifficulty(minutes: totalTimeMinutes, ingredientCount: realIngredientCount)
    }
}
