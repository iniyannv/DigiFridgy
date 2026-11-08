import Testing
import Foundation
@testable import DigiFridgy

struct RecipeRankingTests {
    static func scored(_ id: String, minutes: Double?, ingredients: Int, missing: Int = 0, expiring: Int = 0,
                kcal: Double? = nil, score: Int = 0) -> ScoredRecipe {
        let ings = (0..<ingredients).map { RecipeIngredient(text: "x", food: "food\($0)") }
        let recipe = Recipe(id: id, title: id, imageURL: nil, sourceURL: "", sourceName: nil, ingredients: ings,
                            calories: kcal, servings: 1, totalTimeMinutes: minutes)
        let uses = (0..<expiring).map { RecipeMatch(itemName: "i\($0)", daysUntilExpiry: 1) }
        return ScoredRecipe(recipe: recipe, score: score, uses: uses, missing: (0..<missing).map { "m\($0)" })
    }

    @Test func difficultyMatchesTheBackendRule() {
        #expect(RecipeDifficulty(minutes: 15, ingredientCount: 4) == .easy)
        #expect(RecipeDifficulty(minutes: 25, ingredientCount: 5) == .easy)
        #expect(RecipeDifficulty(minutes: 40, ingredientCount: 8) == .medium)
        #expect(RecipeDifficulty(minutes: 70, ingredientCount: 5) == .medium)
        #expect(RecipeDifficulty(minutes: 90, ingredientCount: 14) == .hard)
        #expect(RecipeDifficulty(minutes: nil, ingredientCount: 14) == .hard)
    }

    @Test func pantryBasicsDontMakeItHarder() {
        let ings = ["salt", "olive oil", "pepper", "eggs", "spinach"].map { RecipeIngredient(text: $0, food: $0) }
        let r = Recipe(id: "a", title: "a", imageURL: nil, sourceURL: "", sourceName: nil, ingredients: ings,
                       totalTimeMinutes: 10)
        #expect(r.realIngredientCount == 2 && r.difficulty == .easy)
    }

    let list: [ScoredRecipe] = [
        Self.scored("hard", minutes: 90, ingredients: 14, missing: 3, expiring: 3, kcal: 800, score: 9),
        Self.scored("medium", minutes: 40, ingredients: 8, missing: 1, expiring: 1, kcal: 300, score: 5),
        Self.scored("easy", minutes: 10, ingredients: 4, missing: 0, expiring: 2, kcal: 500, score: 3),
        Self.scored("noTime", minutes: nil, ingredients: 3, missing: 2, expiring: 0, score: 1),
    ]

    @Test func bestMatchKeepsTheOrder() {
        #expect(RecipeRanking().apply(list).map(\.id) == ["hard", "medium", "easy", "noTime"])
    }

    @Test func sorts() {
        var r = RecipeRanking()
        r.sort = .easiest
        #expect(r.apply(list).map(\.id).prefix(2) == ["easy", "noTime"])
        r.sort = .quickest
        #expect(r.apply(list).map(\.id) == ["easy", "medium", "hard", "noTime"])  // unknown time last
        r.sort = .fewestToBuy
        #expect(r.apply(list).map(\.id) == ["easy", "medium", "noTime", "hard"])
        r.sort = .mostExpiring
        #expect(r.apply(list).map(\.id) == ["hard", "easy", "medium", "noTime"])
        r.sort = .lightest
        #expect(r.apply(list).map(\.id) == ["medium", "easy", "hard", "noTime"])
    }

    @Test func filters() {
        var r = RecipeRanking()
        r.difficulty = .easy
        #expect(r.apply(list).map(\.id) == ["easy", "noTime"])
        r.difficulty = .notHard
        r.time = .thirty
        #expect(r.apply(list).map(\.id) == ["easy"])  // unknown time doesn't count as under 30
        r = RecipeRanking()
        r.nothingToBuy = true
        #expect(r.apply(list).map(\.id) == ["easy"])
        #expect(r.filtersActive && !r.isDefault && r.summary == "Nothing to buy")
    }
}
