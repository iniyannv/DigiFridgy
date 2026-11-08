import Foundation

/// A demo fridge of real, scannable products: every barcode below is a real UPC, and the names, photos,
/// Nutri-Scores, allergens and nutrition come from that product's Open Food Facts page (checked Nov 2026).
nonisolated enum BarcodeDemoData {
    struct Entry: Sendable {
        var barcode: String
        var name: String
        var brand: String
        var category: String
        var imageURL: String?
        var nutrition: Nutrition?
        var nutriScore: String?
        var allergens: [String]
        var categoryTags: [String]
        var count = 1
        var expiresInDays = 7
        var expiryIsEstimated = true
        var possibleRecall = false
    }

    /// In the fridge: some expiring soon, one expired, one possible recall.
    static let fridge: [Entry] = [
        Entry(barcode: "0078742351865", name: "Whole Milk", brand: "Great Value", category: "milk",
              imageURL: "https://images.openfoodfacts.org/images/products/007/874/235/1865/front_en.138.200.jpg",
              nutrition: Nutrition(kcal: 150.0, protein: 8.0, carbs: 12.0, fat: 8.0, sugar: 12.0, sodium: 125.0, fiber: 0.0, servingSize: "1 portion (240 ml)"),
              nutriScore: "c", allergens: ["en:milk"], categoryTags: ["en:dairies", "en:milks-liquid-and-powder", "en:milks", "en:whole-milks"], expiresInDays: 2, expiryIsEstimated: false),
        Entry(barcode: "0861745000010", name: "Pasture Raised Eggs", brand: "Vital Farms", category: "eggs",
              imageURL: "https://images.openfoodfacts.org/images/products/086/174/500/0010/front_en.95.200.jpg",
              nutrition: Nutrition(kcal: 70.0, protein: 6.0, carbs: 0.0, fat: 5.0, sugar: 0.0, sodium: 70.0, fiber: 0.0, servingSize: "1 egg (50 g)"),
              nutriScore: "a", allergens: ["en:eggs"], categoryTags: ["en:eggs-and-their-products", "en:farming-products", "en:eggs", "en:chicken-eggs"],
              count: 12, expiresInDays: 21, expiryIsEstimated: false),
        Entry(barcode: "0070470003023", name: "Original Mountain Blueberry Yogurt", brand: "Yoplait", category: "yogurt",
              imageURL: "https://images.openfoodfacts.org/images/products/007/047/000/3023/front_en.49.200.jpg",
              nutrition: Nutrition(kcal: 140.0, protein: 5.0, carbs: 27.0, fat: 1.5, sugar: 19.0, sodium: 85.0, fiber: nil, servingSize: "1 container (170 g)"),
              nutriScore: "c", allergens: ["en:milk"], categoryTags: ["en:dairies", "en:fermented-foods", "en:fermented-milk-products", "en:desserts"],
              count: 4, expiresInDays: 1, expiryIsEstimated: false),
        Entry(barcode: "0689544001737", name: "Total 0% Greek Yogurt", brand: "Fage", category: "yogurt",
              imageURL: "https://images.openfoodfacts.org/images/products/068/954/400/1737/front_en.32.200.jpg",
              nutrition: Nutrition(kcal: 89.9, protein: 18.0, carbs: 5.0, fat: 0.0, sugar: nil, sodium: nil, fiber: nil, servingSize: "1 serving (170 g)"),
              nutriScore: nil, allergens: [], categoryTags: ["en:dairies", "en:fermented-foods", "en:desserts", "en:fermented-milk-products"], expiresInDays: 9, expiryIsEstimated: false),
        Entry(barcode: "0073420000110", name: "Sour Cream", brand: "Daisy", category: "sour_cream",
              imageURL: "https://images.openfoodfacts.org/images/products/007/342/000/0110/front_en.110.200.jpg",
              nutrition: Nutrition(kcal: 60.0, protein: 1.0, carbs: 1.0, fat: 5.0, sugar: 1.0, sodium: 15.0, fiber: nil, servingSize: "2 tbsp (30 g)"),
              nutriScore: "d", allergens: ["en:milk"], categoryTags: ["en:dairies", "en:fermented-foods", "en:fermented-milk-products", "en:spreads"], expiresInDays: 4, expiryIsEstimated: false, possibleRecall: true),
        Entry(barcode: "0767707001067", name: "Pure Irish Butter, Salted", brand: "Kerrygold", category: "butter",
              imageURL: "https://images.openfoodfacts.org/images/products/076/770/700/1067/front_en.83.200.jpg",
              nutrition: Nutrition(kcal: 100.0, protein: 0.0, carbs: 0.0, fat: 11.0, sugar: 0.0, sodium: 100.0, fiber: nil, servingSize: "1 tbsp (14 g)"),
              nutriScore: "e", allergens: ["en:milk"], categoryTags: ["en:dairies", "en:fats", "en:spreads", "en:spreadable-fats"], expiresInDays: 60, expiryIsEstimated: true),
        Entry(barcode: "0072830005555", name: "Extra Sharp Cheddar", brand: "Tillamook", category: "hard_cheese",
              imageURL: "https://images.openfoodfacts.org/images/products/007/283/000/5555/front_en.5.200.jpg",
              nutrition: Nutrition(kcal: 120.0, protein: 7.0, carbs: 0.0, fat: 9.0, sugar: 0.0, sodium: 170.0, fiber: 0.0, servingSize: "1 ONZ (28 g)"),
              nutriScore: "d", allergens: ["en:milk"], categoryTags: ["en:dairies", "en:fermented-foods", "en:fermented-milk-products", "en:cheeses"], expiresInDays: 25, expiryIsEstimated: false),
        Entry(barcode: "0048001213487", name: "Real Mayonnaise", brand: "Hellmann's", category: "mayonnaise",
              imageURL: "https://images.openfoodfacts.org/images/products/004/800/121/3487/front_en.105.200.jpg",
              nutrition: Nutrition(kcal: 90.0, protein: 0.0, carbs: 0.0, fat: 10.0, sugar: 0.0, sodium: 90.0, fiber: nil, servingSize: "1 Tbsp (13 g)"),
              nutriScore: "e", allergens: ["en:eggs", "en:soybeans"], categoryTags: ["en:condiments", "en:sauces", "en:mayonnaises"], expiresInDays: 50, expiryIsEstimated: true),
        Entry(barcode: "0013000006408", name: "Tomato Ketchup", brand: "Heinz", category: "condiments",
              imageURL: "https://images.openfoodfacts.org/images/products/001/300/000/6408/front_en.26.200.jpg",
              nutrition: Nutrition(kcal: 16.5, protein: 0.2, carbs: 4.1, fat: 0.0, sugar: 3.9, sodium: 122.0, fiber: 0.1, servingSize: "1 Tbsp (17 g)"),
              nutriScore: "d", allergens: ["en:celery"], categoryTags: ["en:plant-based-foods-and-beverages", "en:plant-based-foods", "en:fruits-and-vegetables-based-foods", "en:vegetable-based-foods-and-beverages"], expiresInDays: 120, expiryIsEstimated: true),
        Entry(barcode: "0025293600232", name: "Organic Unsweetened Soymilk", brand: "Silk", category: "plant_milk",
              imageURL: "https://images.openfoodfacts.org/images/products/002/529/360/0232/front_en.190.200.jpg",
              nutrition: Nutrition(kcal: 80.0, protein: 8.0, carbs: 5.0, fat: 3.5, sugar: 1.0, sodium: 80.0, fiber: 2.0, servingSize: "1 Portion (1 cup)"),
              nutriScore: "b", allergens: ["en:soybeans"], categoryTags: ["en:beverages-and-beverages-preparations", "en:plant-based-foods-and-beverages", "en:beverages", "en:plant-based-foods"], expiresInDays: 6, expiryIsEstimated: false),
        Entry(barcode: "0025000044984", name: "Simply Lemonade", brand: "Simply", category: "juice",
              imageURL: "https://images.openfoodfacts.org/images/products/002/500/004/4984/front_en.73.200.jpg",
              nutrition: Nutrition(kcal: 110.0, protein: 0.0, carbs: 29.0, fat: 0.0, sugar: 27.0, sodium: 0.0, fiber: 0.0, servingSize: "240 ml"),
              nutriScore: "e", allergens: [], categoryTags: ["en:beverages-and-beverages-preparations", "en:plant-based-foods-and-beverages", "en:beverages", "en:fruit-based-foods-and-beverages"], expiresInDays: 3, expiryIsEstimated: false),
        Entry(barcode: "0049000050103", name: "Coca-Cola", brand: "Coca-Cola", category: "beverages",
              imageURL: "https://images.openfoodfacts.org/images/products/004/900/005/0103/front_en.96.200.jpg",
              nutrition: Nutrition(kcal: 140.0, protein: 0.0, carbs: 39.0, fat: 0.0, sugar: 39.0, sodium: 45.0, fiber: 0.0, servingSize: "12 fl oz (360 ml)"),
              nutriScore: "e", allergens: [], categoryTags: ["en:beverages-and-beverages-preparations", "en:beverages", "en:non-alcoholic-beverages", "en:carbonated-drinks"], expiresInDays: 90, expiryIsEstimated: true),
        Entry(barcode: "0742365264450", name: "Organic Whole Milk", brand: "Horizon Organic", category: "milk",
              imageURL: "https://images.openfoodfacts.org/images/products/074/236/526/4450/front_en.42.200.jpg",
              nutrition: Nutrition(kcal: 160.0, protein: 8.0, carbs: 13.0, fat: 8.0, sugar: 12.0, sodium: 135.0, fiber: 0.0, servingSize: "1 portion (240 ml)"),
              nutriScore: "c", allergens: [], categoryTags: ["en:dairies", "en:milks-liquid-and-powder", "en:milks", "en:cow-milks"], expiresInDays: -1, expiryIsEstimated: false),
    ]

    /// On the shopping list, with barcodes, so store prices can match the exact product.
    static let shopping: [Entry] = [
        Entry(barcode: "0009800895007", name: "Nutella", brand: "Nutella", category: "pantry",
              imageURL: "https://images.openfoodfacts.org/images/products/000/980/089/5007/front_en.106.200.jpg",
              nutrition: Nutrition(kcal: 200.0, protein: 2.0, carbs: 22.0, fat: 11.0, sugar: 21.0, sodium: 15.0, fiber: 1.0, servingSize: "1 serving (37 g)"),
              nutriScore: "e", allergens: ["en:milk", "en:nuts", "en:soybeans"], categoryTags: ["en:plant-based-foods-and-beverages", "en:plant-based-foods", "en:breakfasts", "en:fats"], expiresInDays: 7, expiryIsEstimated: true),
        Entry(barcode: "0051500255162", name: "Creamy Peanut Butter", brand: "Jif", category: "pantry",
              imageURL: "https://images.openfoodfacts.org/images/products/005/150/025/5162/front_en.197.200.jpg",
              nutrition: Nutrition(kcal: 190.0, protein: 7.0, carbs: 8.0, fat: 16.0, sugar: 3.0, sodium: 140.0, fiber: 2.0, servingSize: "1 serving (33 g)"),
              nutriScore: "c", allergens: ["en:peanuts", "en:soybeans"], categoryTags: ["en:plant-based-foods-and-beverages", "en:plant-based-foods", "en:legumes-and-their-products", "en:breakfasts"], expiresInDays: 7, expiryIsEstimated: true),
        Entry(barcode: "0021000658831", name: "Mac & Cheese", brand: "Kraft", category: "pantry",
              imageURL: "https://images.openfoodfacts.org/images/products/002/100/065/8831/front_en.250.200.jpg",
              nutrition: nil,
              nutriScore: "e", allergens: ["en:gluten", "en:milk"], categoryTags: ["en:plant-based-foods-and-beverages", "en:plant-based-foods", "en:meals", "en:pasta-dishes"], expiresInDays: 7, expiryIsEstimated: true),
    ]

    static var all: [Entry] { fridge + shopping }

    /// Product lookups for every demo barcode (mock mode scans resolve to the real product).
    static var products: [String: ProductInfo] {
        Dictionary(uniqueKeysWithValues: all.map { entry in
            (entry.barcode, ProductInfo(barcode: entry.barcode, name: entry.name, brand: entry.brand,
                                        categoryTags: entry.categoryTags, imageURL: entry.imageURL,
                                        nutrition: entry.nutrition, nutriScore: entry.nutriScore,
                                        allergenTags: entry.allergens))
        })
    }

    static func householdItems(uid: String, now: Date = .now) -> [FridgeItem] {
        func days(_ d: Int) -> Date { Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: d, to: now) ?? now) }
        return fridge.map { entry in
            FridgeItem(barcode: entry.barcode, name: entry.name, brand: entry.brand, category: entry.category,
                       imageURL: entry.imageURL, count: entry.count, addedAt: days(-2), addedBy: uid,
                       expiresAt: days(entry.expiresInDays), expiryIsEstimated: entry.expiryIsEstimated,
                       source: .barcode, nutrition: entry.nutrition, nutriScore: entry.nutriScore,
                       allergens: entry.allergens.isEmpty
                           ? Allergen.implied(byCategory: entry.category).map(\.rawValue) : entry.allergens,
                       recallFlag: entry.possibleRecall
                           ? RecallFlag(recallId: "DEMO-BARCODE-RECALL-2026",
                                        reason: "Sample notice: a sour cream product may contain undeclared allergens. The notice lists no brand, so this is only a possible match.",
                                        date: days(-1),
                                        url: "https://www.fda.gov/safety/recalls-market-withdrawals-safety-alerts",
                                        confidence: .possible)
                           : nil)
        }
    }

    static func shoppingItems() -> [ShoppingListItem] {
        shopping.map { entry in
            ShoppingListItem(name: entry.name.hasPrefix(entry.brand) ? entry.name : "\(entry.brand) \(entry.name)",
                             barcode: entry.barcode)
        }
    }
}
