import Foundation

/// One ingredient a recipe was adapted around: "chicken breast" cooked as "extra-firm tofu" instead.
nonisolated struct IngredientSwap: Codable, Hashable, Sendable {
    /// The ingredient the original recipe calls for ("chicken breast").
    var original: String
    /// What to use instead ("extra-firm tofu").
    var replacement: String
}

/// Adapts recipes that normally contain meat (or, for vegan, animal products) to a meat-free diet filter,
/// so a vegetarian filter still shows "Chicken Fajitas", cooked with tofu instead of chicken.
nonisolated enum IngredientSwapper {
    /// Diets this can adapt a recipe to.
    static let adaptableDiets: Set<DietOption> = [.vegetarian, .vegan, .pescatarian]

    private struct Rule {
        /// Whole words in the ingredient's food name ("chicken", "ground beef" matches "beef").
        var words: Set<String>
        var replacement: String
        /// Generic food name of the replacement, for fridge matching and the shopping list.
        var food: String
        /// Words that mean the ingredient isn't the animal product after all ("coconut milk", "peanut butter").
        var unless: Set<String> = []
    }

    // Order matters: broth and stock before the meats themselves, so "chicken broth" becomes vegetable broth.
    private static let brothRules: [Rule] = [
        Rule(words: ["broth", "stock", "bouillon"], replacement: "vegetable broth", food: "vegetable broth",
             unless: ["vegetable", "veggie", "mushroom"]),
    ]

    private static let meatRules: [Rule] = [
        Rule(words: ["bacon", "pancetta", "sausage", "sausages", "chorizo", "pepperoni", "salami", "ham", "prosciutto",
                     "hot dog", "kielbasa"],
             replacement: "smoked tofu", food: "tofu"),
        Rule(words: ["ground beef", "ground turkey", "ground pork", "ground chicken", "ground lamb", "ground meat",
                     "minced beef", "minced pork", "meatball", "meatballs"],
             replacement: "crumbled firm tofu", food: "tofu"),
        Rule(words: ["chicken", "turkey", "duck", "beef", "steak", "pork", "lamb", "veal", "brisket", "sirloin",
                     "tenderloin", "venison", "goat", "bison", "meat", "drumstick", "drumsticks", "thigh", "thighs"],
             replacement: "extra-firm tofu", food: "tofu"),
    ]

    private static let seafoodRules: [Rule] = [
        Rule(words: ["fish sauce"], replacement: "soy sauce", food: "soy sauce"),
        Rule(words: ["anchovy", "anchovies"], replacement: "capers", food: "capers"),
        Rule(words: ["fish", "salmon", "tuna", "cod", "tilapia", "halibut", "trout", "shrimp", "prawn", "prawns",
                     "crab", "lobster", "scallop", "scallops", "mussels", "clams", "squid", "calamari", "mahi"],
             replacement: "firm tofu", food: "tofu"),
    ]

    private static let veganRules: [Rule] = [
        Rule(words: ["sour cream"], replacement: "cashew cream", food: "cashew cream"),
        Rule(words: ["cheese", "cheddar", "parmesan", "mozzarella", "feta", "ricotta", "gouda", "brie", "provolone",
                     "jack", "parmigiano", "pecorino"],
             replacement: "vegan cheese", food: "vegan cheese", unless: ["vegan", "plant"]),
        Rule(words: ["cream", "creme"], replacement: "coconut cream", food: "coconut cream",
             unless: ["coconut", "cashew", "ice", "tartar"]),
        Rule(words: ["milk"], replacement: "oat milk", food: "oat milk",
             unless: ["coconut", "almond", "oat", "soy", "rice", "cashew", "plant"]),
        Rule(words: ["butter"], replacement: "vegan butter", food: "vegan butter",
             unless: ["peanut", "almond", "cashew", "cocoa", "nut", "apple", "vegan", "plant"]),
        Rule(words: ["yogurt", "yoghurt"], replacement: "plant-based yogurt", food: "plant-based yogurt",
             unless: ["coconut", "soy", "plant"]),
        Rule(words: ["egg", "eggs"], replacement: "flax eggs", food: "flax eggs", unless: ["eggplant", "flax", "noodle", "noodles", "pasta"]),
        Rule(words: ["honey"], replacement: "maple syrup", food: "maple syrup"),
    ]

    /// Whether the filters ask for a diet this can adapt recipes to.
    static func needsAdapting(_ diets: Set<DietOption>) -> Bool { !diets.isDisjoint(with: adaptableDiets) }

    /// The same filters without the meat-free diets, to find recipes worth adapting.
    static func relaxed(_ filters: RecipeFilters) -> RecipeFilters {
        var relaxed = filters
        relaxed.diets.subtract(adaptableDiets)
        return relaxed
    }

    private static func rules(for diets: Set<DietOption>) -> [Rule] {
        if diets.contains(.vegan) { return brothRules + meatRules + seafoodRules + veganRules }
        if diets.contains(.vegetarian) { return brothRules + meatRules + seafoodRules }
        if diets.contains(.pescatarian) { return brothRules + meatRules }
        return []
    }

    private static func matches(_ rule: Rule, food: String) -> Bool {
        let words = Set(ShelfLifeService.tokenize(food))
        let joined = " " + ShelfLifeService.tokenize(food).joined(separator: " ") + " "
        if !rule.unless.isDisjoint(with: words) { return false }
        return rule.words.contains { word in
            word.contains(" ") ? joined.contains(" \(word) ") : words.contains(word)
        }
    }

    /// The recipe cooked to fit `diets`: animal ingredients replaced, the diet labels added, and the swaps listed.
    /// Nil when nothing needed swapping (the recipe was left out for some other reason, so it can't be adapted).
    static func adapt(_ recipe: Recipe, for diets: Set<DietOption>) -> Recipe? {
        let rules = rules(for: diets)
        guard !rules.isEmpty else { return nil }
        var swaps: [IngredientSwap] = []
        var ingredients: [RecipeIngredient] = []
        for ingredient in recipe.ingredients {
            let food = ingredient.food.isEmpty ? ingredient.text : ingredient.food
            guard let rule = rules.first(where: { matches($0, food: food.lowercased()) }) else {
                ingredients.append(ingredient)
                continue
            }
            let original = ingredient.food.isEmpty ? ingredient.text : ingredient.food
            if !swaps.contains(where: { $0.original == original }) {
                swaps.append(IngredientSwap(original: original, replacement: rule.replacement))
            }
            let source = ingredient.text.isEmpty ? original : ingredient.text
            ingredients.append(RecipeIngredient(text: "\(rule.replacement.capitalizedFirst) (instead of \(source))",
                                                food: rule.food))
        }
        guard !swaps.isEmpty else { return nil }

        var adapted = recipe
        adapted.id = recipe.id + "-swap-" + diets.intersection(adaptableDiets).map(\.rawValue).sorted().joined(separator: "-")
        adapted.ingredients = ingredients
        adapted.swaps = swaps
        var labels = recipe.healthLabels ?? []
        for diet in diets.intersection(adaptableDiets) where !labels.contains(where: { $0.lowercased() == diet.edamamParam.value }) {
            labels.append(diet.title)
        }
        if diets.contains(.vegan) && !labels.contains(where: { $0.lowercased() == "vegetarian" }) { labels.append("Vegetarian") }
        adapted.healthLabels = labels
        return adapted
    }

    /// Recipes the diet search returned, then recipes from the unfiltered search adapted to the diet,
    /// skipping any that the diet search already found as-is.
    static func merge(native: [Recipe], candidates: [Recipe], diets: Set<DietOption>) -> [Recipe] {
        let nativeIDs = Set(native.map(\.id))
        let adapted = candidates
            .filter { !nativeIDs.contains($0.id) }
            .compactMap { adapt($0, for: diets) }
        return native + adapted
    }
}

extension Recipe {
    /// "Tofu instead of chicken breast, bacon" for cards.
    var swapSummary: String? {
        guard let swaps, !swaps.isEmpty else { return nil }
        var byReplacement: [(String, [String])] = []
        for swap in swaps {
            if let idx = byReplacement.firstIndex(where: { $0.0 == swap.replacement }) {
                byReplacement[idx].1.append(swap.original)
            } else {
                byReplacement.append((swap.replacement, [swap.original]))
            }
        }
        return byReplacement.map { "\($0.0.capitalizedFirst) instead of \($0.1.joined(separator: ", "))" }
            .joined(separator: "; ")
    }
}
