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

// MARK: - Difficulty, sorting and filters (Recipes tab)

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
    /// Ingredients you'd actually gather (salt, oil and other pantry basics left out).
    nonisolated var realIngredientCount: Int {
        Set(ingredients.map { $0.food.lowercased().trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty && !RecipeScorer.pantryStaples.contains($0) }.count
    }

    nonisolated var difficulty: RecipeDifficulty {
        RecipeDifficulty(minutes: totalTimeMinutes, ingredientCount: realIngredientCount)
    }

    nonisolated var caloriesPerServing: Double? {
        guard let calories, calories > 0 else { return nil }
        return calories / max(servings ?? 1, 1)
    }
}

nonisolated enum RecipeSort: String, CaseIterable, Identifiable, Sendable {
    case bestMatch, easiest, quickest, fewestToBuy, mostExpiring, lightest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bestMatch: "Best match"
        case .easiest: "Easiest first"
        case .quickest: "Quickest first"
        case .fewestToBuy: "Fewest to buy"
        case .mostExpiring: "Uses most expiring"
        case .lightest: "Fewest calories"
        }
    }

    var systemImage: String {
        switch self {
        case .bestMatch: "sparkles"
        case .easiest: "hand.thumbsup"
        case .quickest: "clock"
        case .fewestToBuy: "cart"
        case .mostExpiring: "clock.badge.exclamationmark"
        case .lightest: "flame"
        }
    }
}

nonisolated enum DifficultyFilter: String, CaseIterable, Identifiable, Sendable {
    case any, easy, notHard
    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any difficulty"
        case .easy: "Easy only"
        case .notHard: "Easy or medium"
        }
    }

    func allows(_ d: RecipeDifficulty) -> Bool {
        switch self {
        case .any: true
        case .easy: d == .easy
        case .notHard: d != .hard
        }
    }
}

nonisolated enum TimeLimit: Int, CaseIterable, Identifiable, Sendable {
    case any = 0, fifteen = 15, thirty = 30, hour = 60
    var id: Int { rawValue }
    var label: String { self == .any ? "Any time" : "Under \(rawValue) min" }
}

/// Recipe filters and sort, kept apart from the view so they can be tested.
nonisolated struct RecipeRanking: Equatable, Sendable {
    var sort: RecipeSort = .bestMatch
    var difficulty: DifficultyFilter = .any
    var time: TimeLimit = .any
    var nothingToBuy = false

    var filtersActive: Bool { difficulty != .any || time != .any || nothingToBuy }
    var isDefault: Bool { sort == .bestMatch && !filtersActive }

    /// "Easiest first · Easy only · Under 30 min" for the summary row.
    var summary: String {
        var parts: [String] = []
        if sort != .bestMatch { parts.append(sort.label) }
        if difficulty != .any { parts.append(difficulty.label) }
        if time != .any { parts.append(time.label) }
        if nothingToBuy { parts.append("Nothing to buy") }
        return parts.joined(separator: " · ")
    }

    /// Filters, then sorts. `recipes` arrive in best-match order, which also breaks ties.
    func apply(_ recipes: [ScoredRecipe]) -> [ScoredRecipe] {
        let kept = recipes.filter { r in
            guard difficulty.allows(r.recipe.difficulty) else { return false }
            if time != .any {
                guard let m = r.recipe.totalTimeMinutes, m <= Double(time.rawValue) else { return false }
            }
            return !nothingToBuy || r.missing.isEmpty
        }
        let order = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.id, $0) })
        func rank(_ r: ScoredRecipe) -> Int { order[r.id] ?? 0 }
        let unknown = Double.greatestFiniteMagnitude
        func expiring(_ r: ScoredRecipe) -> Int { r.uses.filter { $0.daysUntilExpiry <= 3 }.count }
        switch sort {
        case .bestMatch:
            return kept
        case .easiest:
            return kept.sorted {
                ($0.recipe.difficulty.rawValue, $0.recipe.totalTimeMinutes ?? unknown, $0.missing.count, rank($0))
                    < ($1.recipe.difficulty.rawValue, $1.recipe.totalTimeMinutes ?? unknown, $1.missing.count, rank($1))
            }
        case .quickest:
            return kept.sorted { ($0.recipe.totalTimeMinutes ?? unknown, rank($0)) < ($1.recipe.totalTimeMinutes ?? unknown, rank($1)) }
        case .fewestToBuy:
            return kept.sorted { ($0.missing.count, rank($0)) < ($1.missing.count, rank($1)) }
        case .mostExpiring:
            return kept.sorted { (-expiring($0), rank($0)) < (-expiring($1), rank($1)) }
        case .lightest:
            return kept.sorted {
                ($0.recipe.caloriesPerServing ?? unknown, rank($0)) < ($1.recipe.caloriesPerServing ?? unknown, rank($1))
            }
        }
    }
}
