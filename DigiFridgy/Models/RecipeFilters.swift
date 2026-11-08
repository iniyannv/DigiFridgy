import Foundation

// MARK: - Filter options (values match Edamam's Recipe Search API v2)

nonisolated enum MealType: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var edamamValue: String { title }
    var symbol: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        }
    }
}

nonisolated enum DishType: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case mainCourse = "Main course"
    case salad = "Salad"
    case soup = "Soup"
    case sandwiches = "Sandwiches"
    case sideDish = "Side dish"
    case starter = "Starter"
    case desserts = "Desserts"
    case drinks = "Drinks"

    var id: String { rawValue }
    var title: String { rawValue }
    var edamamValue: String { rawValue }
}

nonisolated enum Cuisine: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case american = "American"
    case asian = "Asian"
    case chinese = "Chinese"
    case french = "French"
    case indian = "Indian"
    case italian = "Italian"
    case japanese = "Japanese"
    case mediterranean = "Mediterranean"
    case mexican = "Mexican"
    case middleEastern = "Middle Eastern"

    var id: String { rawValue }
    var title: String { rawValue }
    var edamamValue: String { rawValue }
}

nonisolated enum DietOption: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case vegetarian, vegan, pescatarian, keto, glutenFree, dairyFree, highProtein, lowCarb, lowFat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .pescatarian: "Pescatarian"
        case .keto: "Keto"
        case .glutenFree: "Gluten-free"
        case .dairyFree: "Dairy-free"
        case .highProtein: "High protein"
        case .lowCarb: "Low carb"
        case .lowFat: "Low fat"
        }
    }

    /// Edamam query parameter (`health` or `diet`) and its value. The value is also the
    /// lowercased label Edamam puts on matching recipes.
    var edamamParam: (name: String, value: String) {
        switch self {
        case .vegetarian: ("health", "vegetarian")
        case .vegan: ("health", "vegan")
        case .pescatarian: ("health", "pescatarian")
        case .keto: ("health", "keto-friendly")
        case .glutenFree: ("health", "gluten-free")
        case .dairyFree: ("health", "dairy-free")
        case .highProtein: ("diet", "high-protein")
        case .lowCarb: ("diet", "low-carb")
        case .lowFat: ("diet", "low-fat")
        }
    }
}

nonisolated enum RecipeSort: String, CaseIterable, Identifiable, Sendable {
    case bestMatch, quickest, fewestMissing, lightest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bestMatch: "Uses expiring food first"
        case .quickest: "Quickest"
        case .fewestMissing: "Fewest missing ingredients"
        case .lightest: "Fewest calories"
        }
    }
    var shortTitle: String {
        switch self {
        case .bestMatch: "best match"
        case .quickest: "quickest"
        case .fewestMissing: "fewest missing"
        case .lightest: "fewest calories"
        }
    }
    var symbol: String {
        switch self {
        case .bestMatch: "leaf"
        case .quickest: "timer"
        case .fewestMissing: "checklist"
        case .lightest: "flame"
        }
    }

    func sorted(_ recipes: [ScoredRecipe]) -> [ScoredRecipe] {
        // Ranked input is already best-match order; sorts are stable on top of it.
        switch self {
        case .bestMatch: recipes
        case .quickest: Self.stableSort(recipes) { $0.recipe.totalTimeMinutes ?? Double.infinity }
        case .fewestMissing: Self.stableSort(recipes) { Double($0.missing.count) }
        case .lightest: Self.stableSort(recipes) { $0.recipe.caloriesPerServing ?? Double.infinity }
        }
    }

    private static func stableSort(_ recipes: [ScoredRecipe], by key: (ScoredRecipe) -> Double) -> [ScoredRecipe] {
        let keyed: [(key: Double, offset: Int, recipe: ScoredRecipe)] =
            recipes.enumerated().map { (key($0.element), $0.offset, $0.element) }
        let sorted = keyed.sorted { a, b in a.key != b.key ? a.key < b.key : a.offset < b.offset }
        return sorted.map { $0.recipe }
    }
}

// MARK: - Filters

nonisolated struct RecipeFilters: Hashable, Sendable {
    var meal: MealType?
    var dish: DishType?
    var cuisine: Cuisine?
    var diets: Set<DietOption> = []
    /// Total time limit in minutes (recipes without a time are hidden while this is set).
    var maxMinutes: Int?
    /// At most this many ingredients you don't have (pantry staples don't count).
    var maxMissing: Int?

    static let timeChoices = [15, 30, 60]
    static let missingChoices = [0, 2, 4]

    var activeCount: Int {
        [meal != nil, dish != nil, cuisine != nil, maxMinutes != nil, maxMissing != nil].filter { $0 }.count + diets.count
    }
    var isEmpty: Bool { activeCount == 0 }

    /// Whether a recipe's tags and time satisfy the filters. Tags Edamam didn't return don't exclude a recipe
    /// (the server already applied those filters); the time limit does.
    func admits(_ recipe: Recipe) -> Bool {
        if let meal, let types = recipe.mealTypes,
           !types.contains(where: { $0.lowercased().contains(meal.rawValue) }) { return false }
        if let dish, let types = recipe.dishTypes,
           !types.contains(where: { $0.lowercased() == dish.edamamValue.lowercased() }) { return false }
        if let cuisine, let types = recipe.cuisineTypes,
           !types.contains(where: { $0.lowercased() == cuisine.edamamValue.lowercased() }) { return false }
        if !diets.isEmpty, recipe.healthLabels != nil || recipe.dietLabels != nil {
            let labels = recipe.allLabels
            if !diets.allSatisfy({ labels.contains($0.edamamParam.value) }) { return false }
        }
        if let maxMinutes {
            guard let minutes = recipe.totalTimeMinutes, minutes <= Double(maxMinutes) else { return false }
        }
        return true
    }

    func admits(_ scored: ScoredRecipe) -> Bool {
        guard admits(scored.recipe) else { return false }
        if let maxMissing, scored.missing.count > maxMissing { return false }
        return true
    }
}

// MARK: - Request

/// One recipe search: the queries to run plus everything Edamam can filter on server-side.
nonisolated struct RecipeSearchRequest: Hashable, Sendable {
    /// Queries run in parallel; results are merged round-robin so one query can't crowd out the rest.
    var queries: [String]
    /// Allergen exclusions from the user's profile ("dairy-free", "sesame-free").
    var allergenLabels: [String] = []
    var filters = RecipeFilters()

    /// Builds the queries: typed text and/or picked ingredients, else the soonest-expiring items.
    static func queries(text: String, ingredients: [String], expiringQueries: [String]) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries: [String] = []
        if !text.isEmpty {
            if !ingredients.isEmpty { queries.append(([text] + ingredients.prefix(2)).joined(separator: " ")) }
            queries.append(text)
        } else if !ingredients.isEmpty {
            if ingredients.count > 1 { queries.append(ingredients.prefix(3).joined(separator: " ")) }
            queries += ingredients.prefix(3)
        } else {
            queries = expiringQueries
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }
}
