import Testing
import Foundation
@testable import DigiFridgy

struct IngredientSwapTests {
    private func recipe(_ foods: [String], labels: [String] = []) -> Recipe {
        Recipe(id: "r1", title: "Test", imageURL: nil, sourceURL: "", sourceName: nil,
               ingredients: foods.map { RecipeIngredient(text: "1 cup \($0)", food: $0) },
               calories: 1200, servings: 4, totalTimeMinutes: 30, healthLabels: labels)
    }

    @Test func vegetarianSwapsMeatForTofu() throws {
        let adapted = try #require(IngredientSwapper.adapt(recipe(["chicken breast", "bell pepper", "chicken broth"]),
                                                           for: [.vegetarian]))
        #expect(adapted.swaps == [IngredientSwap(original: "chicken breast", replacement: "extra-firm tofu"),
                                  IngredientSwap(original: "chicken broth", replacement: "vegetable broth")])
        #expect(adapted.ingredients.map(\.food) == ["tofu", "bell pepper", "vegetable broth"])
        #expect(adapted.ingredients[0].text.contains("instead of 1 cup chicken breast"))
        #expect(RecipeFilters(diets: [.vegetarian]).admits(adapted))
        #expect(adapted.id != "r1")
    }

    @Test func spicesAndLookalikesAreLeftAlone() {
        // "ground cumin", "eggplant", "beefsteak tomato", "hamburger buns" contain no meat.
        let r = recipe(["ground cumin", "eggplant", "beefsteak tomato", "hamburger buns", "black pepper"])
        #expect(IngredientSwapper.adapt(r, for: [.vegetarian]) == nil)
        #expect(IngredientSwapper.adapt(r, for: [.vegan]) == nil)
    }

    @Test func pescatarianKeepsFishButSwapsMeat() throws {
        let adapted = try #require(IngredientSwapper.adapt(recipe(["salmon", "bacon"]), for: [.pescatarian]))
        #expect(adapted.ingredients.map(\.food) == ["salmon", "tofu"])
    }

    @Test func veganAlsoSwapsDairyAndEggs() throws {
        let adapted = try #require(IngredientSwapper.adapt(recipe(["ground beef", "cheddar cheese", "milk", "eggs",
                                                                   "coconut milk", "peanut butter"]), for: [.vegan]))
        #expect(adapted.ingredients.map(\.food) == ["tofu", "vegan cheese", "oat milk", "flax eggs",
                                                    "coconut milk", "peanut butter"])
        #expect(adapted.allLabels.contains("vegan") && adapted.allLabels.contains("vegetarian"))
    }

    @Test func mergeKeepsNativeResultsFirstAndSkipsDuplicates() {
        let veg = Recipe(id: "veg", title: "Salad", imageURL: nil, sourceURL: "", sourceName: nil,
                         ingredients: [RecipeIngredient(text: "spinach", food: "spinach")])
        let meat = recipe(["chicken"])
        let merged = IngredientSwapper.merge(native: [veg], candidates: [veg, meat], diets: [.vegetarian])
        #expect(merged.map(\.id) == ["veg", "r1-swap-vegetarian"])
    }

    @Test func swapSummaryGroupsByReplacement() throws {
        let adapted = try #require(IngredientSwapper.adapt(recipe(["chicken", "bacon", "pork"]), for: [.vegetarian]))
        #expect(adapted.swapSummary == "Extra-firm tofu instead of chicken, pork; Smoked tofu instead of bacon")
    }

    @Test func mockSearchWithVegetarianFilterAlsoShowsAdaptedMeatRecipes() async throws {
        let service = MockRecipeService()
        var request = RecipeSearchRequest(queries: ["chicken"], filters: RecipeFilters(diets: [.vegetarian]))
        let native = try await service.search(request, userId: nil)
        #expect(!native.contains { $0.title.contains("Chicken") })
        request.filters = IngredientSwapper.relaxed(request.filters)
        let candidates = try await service.search(request, userId: nil)
        let merged = IngredientSwapper.merge(native: native, candidates: candidates, diets: [.vegetarian])
        let fajitas = try #require(merged.first { $0.title == "Chicken Fajitas" })
        #expect(fajitas.swaps?.first?.replacement == "extra-firm tofu")
        #expect(RecipeFilters(diets: [.vegetarian]).admits(fajitas))
    }
}

struct RecipeDisplayTests {
    @Test func everyRecipeHasTimeAndCalories() {
        let ings = ["eggs", "spinach", "mushrooms", "onion", "salt"].map { RecipeIngredient(text: $0, food: $0) }
        let unknown = Recipe(id: "a", title: "a", imageURL: nil, sourceURL: "", sourceName: nil, ingredients: ings)
        #expect(unknown.isTimeEstimated && unknown.isCaloriesEstimated)
        #expect(unknown.timeText.hasPrefix("~") && unknown.timeText.hasSuffix(" min"))
        #expect(unknown.caloriesText.hasPrefix("~") && unknown.caloriesText.hasSuffix(" kcal"))
        #expect(unknown.displayMinutes % 5 == 0 && unknown.displayMinutes > 0)

        var known = unknown
        known.totalTimeMinutes = 25
        known.calories = 1000
        known.servings = 4
        #expect(known.timeText == "25 min")
        #expect(known.caloriesText == "250 kcal")
    }

    @Test func expiringChipWordingIsConsistent() {
        #expect(RecipeCard.expiringText(1) == "Uses 1 expiring")
        #expect(RecipeCard.expiringText(3) == "Uses 3 expiring")
    }
}

struct BasketTests {
    private func store(_ id: String, distance: Double) -> Store {
        Store(id: id, chain: id, name: id, address: "", coordinate: .demoFallback, distanceMiles: distance, isKroger: false)
    }

    @Test func dfwSalesTaxIsAddedToTheSubtotal() {
        let basket = StoreBasket(store: store("a", distance: 1), lines: [
            BasketLine(name: "Milk", price: 3.49, availability: .live),
            BasketLine(name: "Eggs", price: 6.51, availability: .live),
        ])
        #expect(SalesTax.dfwRate == 0.0825)
        #expect(abs(basket.subtotal - 10.00) < 0.001)
        #expect(abs(basket.tax - 0.83) < 0.001)   // 10.00 × 8.25% = 0.825 → 0.83
        #expect(abs(basket.total - 10.83) < 0.001)
    }

    @Test func completeBasketsRankAheadOfCheaperPartialOnes() {
        let partial = StoreBasket(store: store("partial", distance: 1), lines: [
            BasketLine(name: "Milk", price: 1.00, availability: .live),
            BasketLine(name: "Eggs", price: nil, availability: .notCarried),
        ])
        let pricey = StoreBasket(store: store("pricey", distance: 1), lines: [
            BasketLine(name: "Milk", price: 5.00, availability: .sample),
            BasketLine(name: "Eggs", price: 5.00, availability: .sample),
        ])
        let cheap = StoreBasket(store: store("cheap", distance: 3), lines: [
            BasketLine(name: "Milk", price: 3.00, availability: .live),
            BasketLine(name: "Eggs", price: 4.00, availability: .live),
        ])
        #expect(StoreBasket.ranked([partial, pricey, cheap]).map(\.id) == ["cheap", "pricey", "partial"])
        #expect(partial.missingCount == 1 && !partial.isComplete)
        #expect(pricey.isAllSample && !cheap.isAllSample)
    }
}

struct BarcodeDemoTests {
    @Test func everyDemoProductHasAValidUPCCheckDigit() {
        for entry in BarcodeDemoData.all {
            let digits = entry.barcode.compactMap(\.wholeNumberValue)
            #expect(digits.count == 13, "\(entry.barcode)")
            // EAN-13: weights 1,3,1,3… over the first 12 digits.
            let sum = digits.prefix(12).enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
            #expect((10 - sum % 10) % 10 == digits.last, "\(entry.barcode) \(entry.name)")
        }
    }

    @Test func seedItemsAreBarcodedAndLookUp() async throws {
        let items = BarcodeDemoData.householdItems(uid: "u")
        #expect(items.count == BarcodeDemoData.fridge.count)
        #expect(items.allSatisfy { $0.barcode != nil && $0.source == .barcode && $0.imageURL != nil })
        #expect(items.contains { $0.recallFlag?.isPossible == true })
        let found = try await MockProductLookupService().lookup(barcode: "0861745000010")
        #expect(found?.brand == "Vital Farms")
    }
}

struct ShoppingQuantityTests {
    @Test func entriesSavedWithoutAQuantityCountAsOne() throws {
        let old = #"{"id":"a","name":"Milk","addedAt":0,"done":false}"#
        let entry = try JSONDecoder().decode(ShoppingListItem.self, from: Data(old.utf8))
        #expect(entry.count == 1 && entry.quantity == nil)

        var two = entry
        two.quantity = 2
        let round = try JSONDecoder().decode(ShoppingListItem.self, from: JSONEncoder().encode(two))
        #expect(round.count == 2)
    }

    @Test func basketLinesMultiplyByQuantity() {
        let line = BasketLine(name: "Milk", price: 3.49, availability: .live).times(3)
        #expect(line.quantity == 3)
        #expect(abs((line.price ?? 0) - 10.47) < 0.001)
        #expect(BasketLine(name: "Eggs", price: nil, availability: .notCarried).times(2).price == nil)
    }

}
