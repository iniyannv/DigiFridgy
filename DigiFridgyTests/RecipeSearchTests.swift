import Testing
import Foundation
@testable import DigiFridgy

struct RecipeSearchTests {
    private func recipe(_ id: String, _ title: String, minutes: Double? = nil, kcal: Double? = nil, servings: Double? = nil,
                        meal: [String]? = nil, cuisine: [String]? = nil, health: [String]? = nil, diet: [String]? = nil) -> Recipe {
        Recipe(id: id, title: title, imageURL: nil, sourceURL: "https://example.com", sourceName: nil, ingredients: [],
               calories: kcal, servings: servings, totalTimeMinutes: minutes, mealTypes: meal, cuisineTypes: cuisine,
               healthLabels: health, dietLabels: diet)
    }

    @Test func nearDuplicateTitlesCollapse() {
        let recipes = [
            recipe("1", "Chicken and Strawberry Spinach Salad"),
            recipe("2", "Chicken Strawberry Spinach Salad Recipe 5"),
            recipe("3", "Spinach Salad with Chicken, Strawberries"),
            recipe("4", "Chicken Fajitas"),
            recipe("4", "Chicken Fajitas (again, same id)"),
        ]
        let kept = RecipeScorer.removingNearDuplicates(recipes).map(\.id)
        #expect(kept == ["1", "4"])
    }

    @Test func displayTitleDropsRecipeSuffixAndShouting() {
        #expect(RecipeCard.displayTitle("Chicken Strawberry Spinach Salad Recipe 5") == "Chicken Strawberry Spinach Salad")
        #expect(RecipeCard.displayTitle("Easy Pancakes recipe") == "Easy Pancakes")
        #expect(RecipeCard.displayTitle("INSTANT CHOCOLATE MOUSSE") == "Instant Chocolate Mousse")
        #expect(RecipeCard.displayTitle("Recipe") == "Recipe")
    }

    @Test func filtersMatchEdamamTags() {
        var filters = RecipeFilters()
        filters.meal = .lunch
        filters.cuisine = .italian
        filters.diets = [.vegetarian, .highProtein]
        let match = recipe("a", "A", meal: ["lunch/dinner"], cuisine: ["italian"], health: ["Vegetarian"], diet: ["High-Protein"])
        let wrongMeal = recipe("b", "B", meal: ["breakfast"], cuisine: ["italian"], health: ["Vegetarian"], diet: ["High-Protein"])
        let notVegetarian = recipe("c", "C", meal: ["lunch/dinner"], cuisine: ["italian"], health: [], diet: ["High-Protein"])
        #expect(filters.admits(match))
        #expect(!filters.admits(wrongMeal))
        #expect(!filters.admits(notVegetarian))
        #expect(filters.activeCount == 4)
    }

    @Test func timeAndMissingLimits() {
        var filters = RecipeFilters()
        filters.maxMinutes = 30
        #expect(filters.admits(recipe("quick", "Q", minutes: 20)))
        #expect(!filters.admits(recipe("slow", "S", minutes: 45)))
        #expect(!filters.admits(recipe("unknown", "U")))

        filters = RecipeFilters()
        filters.maxMissing = 2
        let scored = ScoredRecipe(recipe: recipe("r", "R"), score: 0, uses: [], missing: ["a", "b", "c"])
        #expect(!filters.admits(scored))
    }

    @Test func queriesPreferTextThenPickedIngredientsThenExpiring() {
        #expect(RecipeSearchRequest.queries(text: " tacos ", ingredients: [], expiringQueries: ["spinach"]) == ["tacos"])
        #expect(RecipeSearchRequest.queries(text: "tacos", ingredients: ["chicken breast"], expiringQueries: [])
            == ["tacos chicken breast", "tacos"])
        #expect(RecipeSearchRequest.queries(text: "", ingredients: ["eggs", "spinach"], expiringQueries: ["x"])
            == ["eggs spinach", "eggs", "spinach"])
        #expect(RecipeSearchRequest.queries(text: "", ingredients: [], expiringQueries: ["a b", "a"]) == ["a b", "a"])
    }

    @Test func edamamParamsIncludeFilters() {
        var filters = RecipeFilters()
        filters.meal = .dinner
        filters.dish = .soup
        filters.diets = [.vegan, .lowCarb]
        filters.maxMinutes = 15
        let params = EdamamRecipeService.filterParams(
            for: RecipeSearchRequest(queries: ["x"], allergenLabels: ["sesame-free"], filters: filters))
        let pairs = params.map { "\($0.0)=\($0.1)" }
        #expect(pairs.contains("health=sesame-free"))
        #expect(pairs.contains("health=vegan"))
        #expect(pairs.contains("diet=low-carb"))
        #expect(pairs.contains("mealType=Dinner"))
        #expect(pairs.contains("dishType=Soup"))
        #expect(pairs.contains("time=1-15"))
    }

    @Test func sortsAreStable() {
        let a = ScoredRecipe(recipe: recipe("a", "A", minutes: 30, kcal: 800, servings: 4), score: 5, uses: [], missing: ["x"])
        let b = ScoredRecipe(recipe: recipe("b", "B", minutes: 10, kcal: 900, servings: 2), score: 3, uses: [], missing: [])
        let c = ScoredRecipe(recipe: recipe("c", "C"), score: 1, uses: [], missing: ["x"])
        #expect(RecipeSort.quickest.sorted([a, b, c]).map(\.id) == ["b", "a", "c"])
        #expect(RecipeSort.fewestMissing.sorted([a, b, c]).map(\.id) == ["b", "a", "c"])
        #expect(RecipeSort.lightest.sorted([a, b, c]).map(\.id) == ["a", "b", "c"])
        #expect(RecipeSort.bestMatch.sorted([a, b, c]).map(\.id) == ["a", "b", "c"])
    }

    @Test func mockSearchHonorsFiltersAndText() async throws {
        let service = MockRecipeService()
        var filters = RecipeFilters()
        filters.meal = .breakfast
        let breakfast = try await service.search(RecipeSearchRequest(queries: [], filters: filters), userId: nil)
        #expect(!breakfast.isEmpty)
        #expect(breakfast.allSatisfy { $0.mealTypes?.contains("breakfast") == true })

        let tacos = try await service.search(RecipeSearchRequest(queries: ["tacos"]), userId: nil)
        #expect(tacos.map(\.title).contains("Chicken Tacos"))
        #expect(!tacos.map(\.title).contains("Guacamole"))
    }

    @Test func savedRecipesPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedRecipeStoreTests"))
        defaults.removePersistentDomain(forName: "SavedRecipeStoreTests")
        let store = SavedRecipeStore(defaults: defaults)
        #expect(store.toggle(recipe("r1", "Soup")))
        #expect(SavedRecipeStore(defaults: defaults).isSaved(recipe("r1", "Soup")))
        #expect(!store.toggle(recipe("r1", "Soup")))
        #expect(SavedRecipeStore(defaults: defaults).recipes.isEmpty)
    }
}
