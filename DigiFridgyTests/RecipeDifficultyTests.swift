import Testing
import Foundation
@testable import DigiFridgy

struct RecipeDifficultyTests {
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
}
