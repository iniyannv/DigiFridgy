import Testing
import Foundation
@testable import DigiFridgy

/// "Cup Noodles Chicken Flavor" used to land in chicken (2-day expiry) because of the word "chicken".
struct PantryCategoryTests {
    let service = ShelfLifeService.shared

    @Test(arguments: [
        ("Cup Noodles Chicken Flavor", "pantry"),
        ("Instant Ramen Beef", "pantry"),
        ("Jasmine Rice", "pantry"),
        ("Boneless Chicken Breast", "chicken"),
        ("Oat Milk", "plant_milk"),
        ("Pasta Sauce", "pasta_sauce"),
        ("Fresh Pasta", "fresh_pasta"),
    ])
    func categoryByName(name: String, expected: String) {
        #expect(service.categoryID(forName: name) == expected)
    }

    @Test func pantryKeepsForMonths() {
        #expect(service.fridgeDays(for: "pantry") >= 90)
        #expect(CategoryStyle.emoji(for: "pantry") == "🥫")
    }
}

@MainActor
struct AIGuessTests {
    @Test func aiNameAndCategoryReplaceTheKeywordMatch() {
        let app = AppState(services: .mock())
        let scanned = FridgeItem(barcode: "0070662030011", name: "Cup Noodles Chicken Flavor 2.25oz",
                                 category: "chicken", expiresAt: app.shelfLife.estimatedExpiry(categoryID: "chicken"),
                                 source: .barcode)
        let tidied = app.applyingAIGuess(scanned, name: "Cup Noodles chicken", category: "pantry")
        #expect(tidied.name == "Cup Noodles chicken")
        #expect(tidied.category == "pantry")
        #expect(tidied.expiresAt == app.shelfLife.estimatedExpiry(categoryID: "pantry"))
    }

    @Test func unknownCategoryFromTheServerIsIgnored() {
        let app = AppState(services: .mock())
        let scanned = FridgeItem(name: "Whole Milk", category: "milk", expiresAt: .now, source: .barcode)
        let same = app.applyingAIGuess(scanned, name: "Something", category: "not_a_category")
        #expect(same.name == "Whole Milk" && same.category == "milk")
    }

    @Test func impliedAllergensFollowTheNewCategory() {
        let app = AppState(services: .mock())
        let implied = Allergen.implied(byCategory: "milk").map(\.rawValue)
        let scanned = FridgeItem(name: "Oatly", category: "milk", expiresAt: .now, source: .barcode, allergens: implied)
        let tidied = app.applyingAIGuess(scanned, name: "Oat milk", category: "plant_milk")
        #expect(tidied.allergens == Allergen.implied(byCategory: "plant_milk").map(\.rawValue))
    }
}
