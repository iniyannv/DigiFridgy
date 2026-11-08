import Testing
import Foundation
@testable import DigiFridgy

struct ShelfLifeServiceTests {
    let service = ShelfLifeService.shared

    @Test func bundledCategoriesLoad() {
        #expect(service.categories.count >= 50)
        #expect(service.fridgeDays(for: "milk") == 7)
        #expect(service.fridgeDays(for: "nonexistent") == 7)
    }

    @Test(arguments: [
        (["en:dairies", "en:milks", "en:whole-milks"], "milk"),
        (["en:dairies", "en:yogurts", "en:fruit-yogurts", "en:blueberry-yogurts"], "yogurt"),
        (["en:eggs", "en:chicken-eggs"], "eggs"),
        (["en:dairies", "en:fermented-milk-products", "en:cheeses"], "hard_cheese"),
        (["en:dairies", "en:cream-cheeses"], "cream_cheese"),
        (["en:plant-based-foods", "en:plant-based-beverages", "en:almond-milks"], "plant_milk"),
        (["en:spreads", "en:peanut-butters"], "condiments"),
        (["en:something-unmapped"], "other"),
    ])
    func mapsOpenFoodFactsTags(tags: [String], expected: String) {
        #expect(service.categoryID(forOFFTags: tags) == expected)
    }

    @Test(arguments: [
        ("Organic Baby Spinach 5oz", "leafy_greens"),
        ("Sour Cream", "sour_cream"),
        ("Ice Cream Sandwich", "ice_cream"),
        ("Boneless chicken breast", "chicken"),
        ("Strawberries", "berries"),
    ])
    func mapsProductNames(name: String, expected: String) {
        #expect(service.categoryID(forName: name) == expected)
    }

    @Test func estimatedExpiryAddsCategoryDays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = service.estimatedExpiry(categoryID: "chicken", from: start)
        // Expiry is a calendar day: two days after the day it was added.
        #expect(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start), to: expiry).day == 2)
        #expect(expiry == Calendar.current.startOfDay(for: expiry))
    }
}

struct RecipeScorerTests {
    let scorer = RecipeScorer()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, _ category: String, days: Int) -> FridgeItem {
        FridgeItem(name: name, category: category,
                   expiresAt: Calendar.current.date(byAdding: .day, value: days, to: now)!, source: .receipt)
    }

    private func recipe(_ id: String, _ foods: [String]) -> Recipe {
        Recipe(id: id, title: id, imageURL: nil, sourceURL: "https://example.com", sourceName: nil,
               ingredients: foods.map { RecipeIngredient(text: $0, food: $0) })
    }

    @Test func expiringIngredientsScoreHigher() {
        let items = [item("Baby Spinach", "leafy_greens", days: 1), item("Large Eggs", "eggs", days: 20)]
        let scored = scorer.score(recipe("r", ["spinach", "eggs", "garlic", "salt"]), items: items, now: now)
        // spinach +3 (≤3 days), eggs +1, garlic −1, salt is a pantry staple (0)
        #expect(scored.score == 3)
        #expect(scored.missing == ["garlic"])
        #expect(scored.uses.first?.itemName == "spinach")
    }

    @Test func rankingPutsExpiringFirst() {
        let items = [item("Baby Spinach", "leafy_greens", days: 1), item("Butter", "butter", days: 40)]
        let ranked = scorer.rank([recipe("butter-only", ["butter", "flour"]), recipe("spinach", ["spinach"])],
                                 items: items, now: now)
        #expect(ranked.first?.recipe.id == "spinach")
    }

    @Test func queriesUseGenericTermsOfSoonestItems() {
        let items = [item("Great Value Whole Milk", "milk", days: 2), item("Baby Spinach", "leafy_greens", days: 1),
                     item("Butter", "butter", days: 50)]
        let queries = scorer.queries(for: items, now: now)
        #expect(queries.first == "spinach whole milk butter")
        #expect(!queries.joined().contains("Great Value"))
    }

    @Test func expiredItemsAndFalseFriendsDontMatch() {
        let items = [item("Leftover Pasta", "prepared_meals", days: -1), item("Flour Tortillas", "tortillas", days: 5),
                     item("Romaine Hearts", "leafy_greens", days: 2)]
        let scored = scorer.score(recipe("r", ["pasta", "flour", "spinach", "tortillas"]), items: items, now: now)
        #expect(scored.uses.map(\.itemName) == ["tortillas"])
        #expect(scored.missing == ["pasta", "spinach"])
    }

    @Test func keyTermComesFromName() {
        #expect(scorer.keyTerm(for: item("Boneless Chicken Breast", "chicken", days: 1)) == "chicken breast")
        #expect(scorer.keyTerm(for: item("Original Mountain Blueberry Yogurt", "yogurt", days: 1)) == "yogurt")
    }

    @Test func pluralsMatch() {
        #expect(RecipeScorer.matches(food: "eggs", term: "egg"))
        #expect(RecipeScorer.matches(food: "fresh strawberries", term: "strawberry"))
        #expect(!RecipeScorer.matches(food: "eggplant", term: "egg"))
    }
}

struct MockPriceServiceTests {
    let service = MockPriceService()

    @Test func pricesAreDeterministic() {
        let a = service.price(upc: "0078742351865", name: "Milk", chain: "Walmart", referencePrice: 3.49)
        let b = service.price(upc: "078742351865", name: "Whole milk", chain: "Walmart", referencePrice: 3.49)
        #expect(a == b)   // UPC-A and EAN-13 forms normalize to the same key
    }

    @Test func pricesStayWithinTwentyPercent() {
        for chain in OtherChain.allCases {
            for upc in ["0078742351865", "0070470003023", "0078742127088", "0099482434090"] {
                let price = service.price(upc: upc, name: "x", chain: chain.rawValue, referencePrice: 4.00)
                #expect(price >= 3.19 && price <= 4.89, "\(chain.rawValue) \(upc) → \(price)")
            }
        }
    }

    @Test func pricesDifferAcrossChains() {
        let prices = Set(OtherChain.allCases.map {
            service.price(upc: "0078742351865", name: "Milk", chain: $0.rawValue, referencePrice: 3.49)
        })
        #expect(prices.count > 1)
    }

    @Test func retailRoundingEndsInNine() {
        #expect(MockPriceService.retailRound(3.4312) == 3.49)
        #expect(MockPriceService.retailRound(2.0) == 2.09)
    }
}

struct DTODecodingTests {
    @Test func offProductWithMissingFieldsDecodes() throws {
        let json = #"{"status":1,"product":{"product_name":"Mystery Yogurt"}}"#
        let response = try JSONDecoder().decode(OFFProductResponse.self, from: Data(json.utf8))
        let info = try #require(response.toProductInfo(barcode: "123"))
        #expect(info.name == "Mystery Yogurt")
        #expect(info.brand == nil)
        #expect(info.nutrition == nil)
        #expect(info.nutriScore == nil)
        #expect(info.allergenTags.isEmpty)
    }

    @Test func offNutrimentsAcceptStringsAndPreferServing() throws {
        let json = #"""
        {"status":1,"product":{"product_name":"Milk","brands":"Great Value, Walmart","nutriscore_grade":"C",
         "serving_size":"240 ml","allergens_tags":["en:milk"],"categories_tags":["en:milks"],
         "nutriments":{"energy-kcal_serving":"150","energy-kcal_100g":62,"proteins_serving":8,"sodium_serving":0.12,
                       "fat_serving":8,"sugars_serving":"12.0","carbohydrates_serving":12,"fiber_serving":"n/a"}}}
        """#
        let response = try JSONDecoder().decode(OFFProductResponse.self, from: Data(json.utf8))
        let info = try #require(response.toProductInfo(barcode: "0078742351865"))
        #expect(info.brand == "Great Value")
        #expect(info.nutriScore == "c")
        #expect(info.nutrition?.kcal == 150)
        #expect(info.nutrition?.sodium == 120)      // grams → mg
        #expect(info.nutrition?.sugar == 12)
        #expect(info.nutrition?.fiber == nil)
        #expect(info.nutrition?.servingSize == "240 ml")
    }

    @Test func offNotFoundReturnsNil() throws {
        let json = #"{"status":0,"status_verbose":"product not found"}"#
        let response = try JSONDecoder().decode(OFFProductResponse.self, from: Data(json.utf8))
        #expect(response.toProductInfo(barcode: "000") == nil)
    }

    @Test func fridgeItemDecodesWithMissingOptionalFields() throws {
        let json = #"{"id":"abc","name":"Milk","category":"milk","count":2,"expiresAt":1800000000,"source":"barcode"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let item = try decoder.decode(FridgeItem.self, from: Data(json.utf8))
        #expect(item.count == 2)
        #expect(item.allergens.isEmpty)
        #expect(item.expiryIsEstimated)
    }
}

struct RecallMatcherTests {
    let matcher = RecallMatcher()

    private func recall(description: String, code: String = "", firm: String = "") -> Recall {
        Recall(id: "F-1", reason: "Listeria", productDescription: description, codeInfo: code, firm: firm,
               date: .now, classification: "Class I", url: "https://fda.gov")
    }

    @Test func matchesSpacedUPCInCodeInfo() {
        let item = FridgeItem(barcode: "0078742351865", name: "Whole Milk", brand: "Great Value", category: "milk",
                              expiresAt: .now, source: .barcode)
        #expect(matcher.matches(item, recall(description: "Milk, 1 gallon", code: "UPC 0 78742 35186 5, Best by 12/01")))
    }

    @Test func matchesBrandAndName() {
        let item = FridgeItem(name: "Classic Hummus", brand: "Sabra", category: "hummus", expiresAt: .now, source: .barcode)
        #expect(matcher.matches(item, recall(description: "Sabra Classic Hummus 10 oz tubs", firm: "Sabra Dipping Co")))
    }

    @Test func doesNotMatchUnrelated() {
        let item = FridgeItem(name: "Baby Spinach", brand: "Taylor Farms", category: "leafy_greens", expiresAt: .now, source: .receipt)
        #expect(!matcher.matches(item, recall(description: "Frozen shrimp, 2 lb bag", firm: "Ocean Foods")))
    }
}
