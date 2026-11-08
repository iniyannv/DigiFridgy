import Foundation

/// Ranks recipes by "use expiring food first".
/// +3 per ingredient matching a fridge item expiring in ≤3 days, +1 per other fridge match, −1 per missing ingredient.
nonisolated struct RecipeScorer: Sendable {
    /// Ingredients assumed to be in every pantry; never counted as missing.
    static let pantryStaples: Set<String> = [
        "salt", "pepper", "black pepper", "water", "oil", "olive oil", "vegetable oil", "canola oil",
        "sugar", "flour", "all-purpose flour", "ice", "cooking spray", "kosher salt", "sea salt",
    ]

    var shelfLife: ShelfLifeService = .shared

    /// The generic name of a fridge item: the category keyword found in its name
    /// ("Baby Spinach" → "spinach"), else the category's search term, else its last word.
    func keyTerm(for item: FridgeItem) -> String {
        if let keyword = shelfLife.matchedKeyword(in: item.name, categoryID: item.category) {
            return keyword.lowercased()
        }
        if let term = shelfLife.category(id: item.category)?.searchTerm { return term.lowercased() }
        return ShelfLifeService.tokenize(item.name).last ?? item.name.lowercased()
    }

    /// Terms a recipe ingredient can match: the key term plus the name's head noun ("cheddar", "tomatoes").
    func matchTerms(for item: FridgeItem) -> [String] {
        var terms = [keyTerm(for: item)]
        if let head = ShelfLifeService.tokenize(item.name).last(where: { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }),
           !terms.contains(head) {
            terms.append(head)
        }
        return terms
    }

    /// Search queries built from the soonest-expiring items (generic names, not brands).
    func queries(for items: [FridgeItem], now: Date = .now) -> [String] {
        let soonest = items.filter { $0.count > 0 && $0.daysUntilExpiry(now: now) >= 0 }
            .sorted { $0.expiresAt < $1.expiresAt }
            .prefix(5)
        var seen = Set<String>()
        let terms = soonest.compactMap { item -> String? in
            let term = keyTerm(for: item)
            return seen.insert(term).inserted ? term : nil
        }
        guard !terms.isEmpty else { return [] }
        var queries = [terms.prefix(3).joined(separator: " ")]
        if terms.count >= 2 { queries.append(terms.prefix(2).joined(separator: " ")) }
        queries += terms.prefix(3)
        var unique = Set<String>()
        return queries.filter { unique.insert($0).inserted }
    }

    func score(_ recipe: Recipe, items: [FridgeItem], now: Date = .now) -> ScoredRecipe {
        // Expired food shouldn't drive suggestions; soonest-expiring items match first.
        let available = items.filter { $0.count > 0 && $0.daysUntilExpiry(now: now) >= 0 }
            .sorted { $0.expiresAt < $1.expiresAt }
        let itemTerms = available.map { ($0, matchTerms(for: $0)) }
        var score = 0
        var uses: [RecipeMatch] = []
        var usedItemIDs = Set<String>()
        var missing: [String] = []

        for ingredient in recipe.ingredients {
            let food = ingredient.food.lowercased().trimmingCharacters(in: .whitespaces)
            guard !food.isEmpty, !Self.pantryStaples.contains(food) else { continue }
            let match = itemTerms.first { _, terms in terms.contains { Self.matches(food: food, term: $0) } }?.0
            if let match {
                guard usedItemIDs.insert(match.id).inserted else { continue }
                let days = match.daysUntilExpiry(now: now)
                score += days <= 3 ? 3 : 1
                uses.append(RecipeMatch(itemName: keyTerm(for: match), daysUntilExpiry: days,
                                        expiryIsEstimated: match.expiryIsEstimated))
            } else if !missing.contains(food) {
                score -= 1
                missing.append(food)
            }
        }
        uses.sort { $0.daysUntilExpiry < $1.daysUntilExpiry }
        return ScoredRecipe(recipe: recipe, score: score, uses: uses, missing: missing)
    }

    func rank(_ recipes: [Recipe], items: [FridgeItem], now: Date = .now) -> [ScoredRecipe] {
        recipes.map { score($0, items: items, now: now) }
            .sorted { ($0.score, -$0.missing.count) > ($1.score, -$1.missing.count) }
    }

    /// "baby spinach" matches "spinach"; "milk" matches "whole milk"; "eggs" matches "egg".
    static func matches(food: String, term: String) -> Bool {
        let f = ShelfLifeService.tokenize(food).map(singular)
        let t = ShelfLifeService.tokenize(term).map(singular)
        guard !f.isEmpty, !t.isEmpty else { return false }
        if t.count <= f.count {
            for start in 0...(f.count - t.count) where Array(f[start..<start + t.count]) == t { return true }
        }
        if f.count < t.count {
            for start in 0...(t.count - f.count) where Array(t[start..<start + f.count]) == f { return true }
        }
        return false
    }

    private static func singular(_ word: String) -> String {
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
