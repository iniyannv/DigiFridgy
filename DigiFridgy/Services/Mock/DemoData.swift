import Foundation

/// Seed data for the demo household, mock product lookups and mock recipes.
nonisolated enum DemoData {
    /// Real barcodes that resolve on Open Food Facts — handy for typing into the simulator.
    static let seedBarcodes: [(code: String, label: String)] = [
        ("0078742351865", "Great Value Whole Milk"),
        ("0070470003023", "Yoplait Blueberry Yogurt"),
        ("0078742127088", "Great Value Large Eggs"),
        ("0099482434090", "365 Cheddar Cheese"),
        ("0742365264450", "Horizon Organic Whole Milk"),
        ("0048500202807", "Tropicana Orange Juice"),
    ]

    static let products: [String: ProductInfo] = [
        "0078742351865": ProductInfo(
            barcode: "0078742351865", name: "Whole Milk", brand: "Great Value",
            categoryTags: ["en:dairies", "en:milks", "en:whole-milks"], imageURL: nil,
            nutrition: Nutrition(kcal: 150, protein: 8, carbs: 12, fat: 8, sugar: 12, sodium: 120, fiber: 0, servingSize: "1 cup (240 ml)"),
            nutriScore: "c", allergenTags: ["en:milk"]),
        "0070470003023": ProductInfo(
            barcode: "0070470003023", name: "Original Mountain Blueberry Yogurt", brand: "Yoplait",
            categoryTags: ["en:dairies", "en:yogurts", "en:fruit-yogurts", "en:blueberry-yogurts"], imageURL: nil,
            nutrition: Nutrition(kcal: 140, protein: 5, carbs: 24, fat: 2, sugar: 18, sodium: 85, fiber: 0, servingSize: "1 container (170 g)"),
            nutriScore: "c", allergenTags: ["en:milk"]),
        "0078742127088": ProductInfo(
            barcode: "0078742127088", name: "Large White Eggs", brand: "Great Value",
            categoryTags: ["en:eggs", "en:chicken-eggs"], imageURL: nil,
            nutrition: Nutrition(kcal: 70, protein: 6, carbs: 0, fat: 5, sugar: 0, sodium: 70, fiber: 0, servingSize: "1 egg (50 g)"),
            nutriScore: "a", allergenTags: ["en:eggs"]),
        "0099482434090": ProductInfo(
            barcode: "0099482434090", name: "Cheddar Cheese", brand: "365 Everyday Value",
            categoryTags: ["en:dairies", "en:cheeses"], imageURL: nil,
            nutrition: Nutrition(kcal: 110, protein: 7, carbs: 1, fat: 9, sugar: 0, sodium: 180, fiber: 0, servingSize: "1 oz (28 g)"),
            nutriScore: "d", allergenTags: ["en:milk"]),
        "0742365264450": ProductInfo(
            barcode: "0742365264450", name: "Organic Whole Milk", brand: "Horizon Organic",
            categoryTags: ["en:dairies", "en:milks", "en:cow-milks"], imageURL: nil,
            nutrition: Nutrition(kcal: 150, protein: 8, carbs: 12, fat: 8, sugar: 12, sodium: 125, fiber: 0, servingSize: "1 cup (240 ml)"),
            nutriScore: "c", allergenTags: ["en:milk"]),
        "0048500202807": ProductInfo(
            barcode: "0048500202807", name: "100% Orange Juice, No Pulp", brand: "Tropicana",
            categoryTags: ["en:beverages", "en:fruit-juices", "en:orange-juices"], imageURL: nil,
            nutrition: Nutrition(kcal: 110, protein: 2, carbs: 26, fat: 0, sugar: 22, sodium: 0, fiber: 0, servingSize: "8 fl oz (240 ml)"),
            nutriScore: "c", allergenTags: []),
    ]

    static func typicalNutrition(forCategory id: String) -> Nutrition? {
        switch id {
        case "milk": Nutrition(kcal: 120, protein: 8, carbs: 12, fat: 5, sugar: 12, sodium: 115, fiber: 0, servingSize: "1 cup")
        case "eggs": Nutrition(kcal: 72, protein: 6, carbs: 0, fat: 5, sugar: 0, sodium: 71, fiber: 0, servingSize: "1 egg")
        case "leafy_greens": Nutrition(kcal: 7, protein: 1, carbs: 1, fat: 0, sugar: 0, sodium: 24, fiber: 1, servingSize: "1 cup")
        case "berries": Nutrition(kcal: 49, protein: 1, carbs: 12, fat: 0, sugar: 7, sodium: 2, fiber: 3, servingSize: "1 cup")
        case "chicken": Nutrition(kcal: 165, protein: 31, carbs: 0, fat: 4, sugar: 0, sodium: 74, fiber: 0, servingSize: "100 g")
        case "bananas": Nutrition(kcal: 105, protein: 1, carbs: 27, fat: 0, sugar: 14, sodium: 1, fiber: 3, servingSize: "1 medium")
        case "shredded_cheese", "hard_cheese": Nutrition(kcal: 110, protein: 7, carbs: 1, fat: 9, sugar: 0, sodium: 180, fiber: 0, servingSize: "1 oz")
        case "yogurt": Nutrition(kcal: 100, protein: 17, carbs: 6, fat: 0, sugar: 4, sodium: 60, fiber: 0, servingSize: "170 g")
        case "avocado": Nutrition(kcal: 240, protein: 3, carbs: 13, fat: 22, sugar: 1, sodium: 11, fiber: 10, servingSize: "1 avocado")
        default: nil
        }
    }

    // MARK: Demo household (~14 items: some expiring tomorrow, allergen hits, one recall)

    static func householdItems(uid: String, now: Date = .now) -> [FridgeItem] {
        func days(_ d: Int) -> Date { Calendar.current.date(byAdding: .day, value: d, to: now) ?? now }
        func item(_ name: String, brand: String? = nil, category: String, count: Int = 1, expires: Int,
                  estimated: Bool = true, source: ItemSource = .receipt, barcode: String? = nil,
                  allergens: [String] = [], nutriScore: String? = nil, recall: RecallFlag? = nil) -> FridgeItem {
            FridgeItem(barcode: barcode, name: name, brand: brand, category: category, count: count,
                       addedAt: days(-2), addedBy: uid, expiresAt: days(expires), expiryIsEstimated: estimated,
                       source: source, nutrition: typicalNutrition(forCategory: category), nutriScore: nutriScore,
                       allergens: allergens.isEmpty ? Allergen.implied(byCategory: category).map(\.rawValue) : allergens,
                       recallFlag: recall)
        }
        return [
            item("Baby Spinach", brand: "Taylor Farms", category: "leafy_greens", expires: 1, nutriScore: "a"),
            item("Boneless Chicken Breast", category: "chicken", count: 2, expires: 1),
            item("Strawberries", category: "berries", expires: 2, nutriScore: "a"),
            item("Cherry Tomatoes", category: "tomatoes", expires: 3, nutriScore: "a"),
            item("Hass Avocados", category: "avocado", count: 3, expires: 3, nutriScore: "a"),
            item("White Mushrooms", category: "mushrooms", expires: 4),
            item("Bell Peppers", category: "peppers", count: 2, expires: 6),
            item("Classic Hummus", brand: "Sabra", category: "hummus", expires: 6, source: .barcode,
                 barcode: "0040822011006", allergens: ["en:sesame-seeds"], nutriScore: "c"),
            item("Romaine Hearts", category: "leafy_greens", expires: 5, nutriScore: "a",
                 recall: RecallFlag(recallId: "DEMO-F-0001-2026", reason: "Possible E. coli O157:H7 contamination.",
                                    date: days(-1), url: "https://www.fda.gov/safety/recalls-market-withdrawals-safety-alerts")),
            item("Pasture Raised Eggs", brand: "Vital Farms", category: "eggs", count: 12, expires: 20, estimated: false,
                 source: .barcode, barcode: "0861745000010", allergens: ["en:eggs"], nutriScore: "a"),
            item("Shredded Sharp Cheddar", brand: "Tillamook", category: "shredded_cheese", expires: 18, nutriScore: "d"),
            item("Flour Tortillas", category: "tortillas", count: 10, expires: 10, nutriScore: "c"),
            item("Salted Butter", category: "butter", expires: 45, nutriScore: "e"),
            item("Leftover Pasta", category: "prepared_meals", expires: -1),
        ]
    }

    // MARK: Mock recipes

    private static func recipe(_ id: String, _ title: String, _ foods: [String], kcal: Double, minutes: Double,
                               search: String, meal: [String], dish: [String], cuisine: [String],
                               labels: [String] = [], servings: Double = 4) -> Recipe {
        let dietLabels = labels.filter { ["High-Protein", "Low-Carb", "Low-Fat", "Balanced"].contains($0) }
        return Recipe(id: "mock-\(id)", title: title, imageURL: nil,
                      sourceURL: "https://www.allrecipes.com/search?q=\(search)", sourceName: "Allrecipes",
                      ingredients: foods.map { RecipeIngredient(text: $0, food: $0) },
                      calories: kcal, servings: servings, totalTimeMinutes: minutes,
                      mealTypes: meal, dishTypes: dish, cuisineTypes: cuisine,
                      healthLabels: labels.filter { !dietLabels.contains($0) }, dietLabels: dietLabels)
    }

    static let recipes: [Recipe] = [
        recipe("1", "Spinach & Mushroom Frittata", ["eggs", "spinach", "mushrooms", "cheddar cheese", "salt", "pepper"], kcal: 1180, minutes: 25, search: "spinach+frittata",
               meal: ["breakfast"], dish: ["main course"], cuisine: ["italian"], labels: ["Vegetarian", "Gluten-Free", "Keto-Friendly", "Low-Carb"]),
        recipe("2", "Chicken Fajitas", ["chicken breast", "bell pepper", "onion", "tortillas", "lime", "olive oil"], kcal: 1900, minutes: 30, search: "chicken+fajitas",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["mexican"], labels: ["Dairy-Free", "High-Protein"]),
        recipe("3", "Strawberry Spinach Salad", ["spinach", "strawberries", "avocado", "almonds", "balsamic vinegar"], kcal: 820, minutes: 10, search: "strawberry+spinach+salad",
               meal: ["lunch/dinner"], dish: ["salad"], cuisine: ["american"], labels: ["Vegan", "Vegetarian", "Gluten-Free", "Dairy-Free"]),
        recipe("4", "Creamy Tuscan Chicken", ["chicken breast", "spinach", "cherry tomatoes", "cream", "garlic", "parmesan"], kcal: 2400, minutes: 35, search: "tuscan+chicken",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["italian"], labels: ["Gluten-Free", "Keto-Friendly", "High-Protein", "Low-Carb"]),
        recipe("5", "Chicken Quesadillas", ["chicken", "tortillas", "cheddar cheese", "bell pepper", "salsa"], kcal: 2100, minutes: 20, search: "chicken+quesadilla",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["mexican"], labels: ["High-Protein"]),
        recipe("6", "Guacamole", ["avocado", "tomato", "onion", "cilantro", "lime", "salt"], kcal: 700, minutes: 10, search: "guacamole",
               meal: ["snack"], dish: ["starter"], cuisine: ["mexican"], labels: ["Vegan", "Vegetarian", "Gluten-Free", "Dairy-Free", "Keto-Friendly"]),
        recipe("7", "Berry Yogurt Parfait", ["yogurt", "strawberries", "blueberries", "granola", "honey"], kcal: 900, minutes: 5, search: "yogurt+parfait",
               meal: ["breakfast"], dish: ["desserts"], cuisine: ["american"], labels: ["Vegetarian"]),
        recipe("8", "Classic French Toast", ["bread", "eggs", "milk", "butter", "cinnamon", "sugar"], kcal: 1400, minutes: 20, search: "french+toast",
               meal: ["breakfast"], dish: ["main course"], cuisine: ["french"], labels: ["Vegetarian"]),
        recipe("9", "Veggie Hummus Wraps", ["tortillas", "hummus", "spinach", "bell pepper", "cucumber"], kcal: 1100, minutes: 10, search: "hummus+wrap",
               meal: ["lunch/dinner"], dish: ["sandwiches"], cuisine: ["middle eastern"], labels: ["Vegan", "Vegetarian", "Dairy-Free"]),
        recipe("10", "Mushroom Omelette", ["eggs", "mushrooms", "butter", "milk", "salt"], kcal: 600, minutes: 15, search: "mushroom+omelette",
               meal: ["breakfast"], dish: ["main course"], cuisine: ["french"], labels: ["Vegetarian", "Gluten-Free", "Keto-Friendly", "Low-Carb"], servings: 2),
        recipe("11", "Pasta Primavera", ["pasta", "bell pepper", "cherry tomatoes", "spinach", "parmesan", "olive oil"], kcal: 1700, minutes: 30, search: "pasta+primavera",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["italian"], labels: ["Vegetarian"]),
        recipe("12", "Orange Banana Smoothie", ["orange juice", "banana", "yogurt", "ice"], kcal: 500, minutes: 5, search: "orange+smoothie",
               meal: ["breakfast", "snack"], dish: ["drinks"], cuisine: ["american"], labels: ["Vegetarian", "Gluten-Free", "Low-Fat"], servings: 2),
        recipe("13", "Chicken Tacos", ["chicken breast", "tortillas", "avocado", "cherry tomatoes", "onion", "lime", "cilantro"], kcal: 1800, minutes: 25, search: "chicken+tacos",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["mexican"], labels: ["Dairy-Free", "High-Protein"]),
        recipe("14", "Creamy Mushroom Soup", ["mushrooms", "onion", "garlic", "butter", "cream", "vegetable broth"], kcal: 1200, minutes: 40, search: "mushroom+soup",
               meal: ["lunch/dinner"], dish: ["soup"], cuisine: ["french"], labels: ["Vegetarian", "Gluten-Free", "Low-Carb"]),
        recipe("15", "Chicken Stir-Fry", ["chicken breast", "bell pepper", "mushrooms", "soy sauce", "garlic", "ginger", "rice"], kcal: 1900, minutes: 25, search: "chicken+stir+fry",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["chinese"], labels: ["Dairy-Free", "High-Protein"]),
        recipe("16", "Stuffed Bell Peppers", ["bell pepper", "rice", "cherry tomatoes", "cheddar cheese", "black beans", "onion"], kcal: 1600, minutes: 50, search: "stuffed+peppers",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["american"], labels: ["Vegetarian", "Gluten-Free"]),
        recipe("17", "Avocado Toast with Egg", ["bread", "avocado", "eggs", "lemon", "chili flakes"], kcal: 700, minutes: 10, search: "avocado+toast",
               meal: ["breakfast"], dish: ["sandwiches"], cuisine: ["american"], labels: ["Vegetarian", "Dairy-Free"], servings: 2),
        recipe("18", "Caprese Salad", ["cherry tomatoes", "mozzarella", "basil", "balsamic vinegar", "olive oil"], kcal: 900, minutes: 10, search: "caprese+salad",
               meal: ["lunch/dinner"], dish: ["salad", "starter"], cuisine: ["italian"], labels: ["Vegetarian", "Gluten-Free", "Keto-Friendly", "Low-Carb"]),
        recipe("19", "Chicken Tikka Masala", ["chicken breast", "yogurt", "cherry tomatoes", "onion", "garlic", "garam masala", "cream", "rice"], kcal: 2600, minutes: 45, search: "chicken+tikka+masala",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["indian"], labels: ["Gluten-Free", "High-Protein"]),
        recipe("20", "Strawberry Shortcake", ["strawberries", "flour", "butter", "cream", "sugar", "baking powder"], kcal: 2200, minutes: 35, search: "strawberry+shortcake",
               meal: ["snack"], dish: ["desserts"], cuisine: ["american"], labels: ["Vegetarian"], servings: 6),
        recipe("21", "Spinach Mushroom Quesadilla", ["tortillas", "spinach", "mushrooms", "cheddar cheese", "onion"], kcal: 1300, minutes: 15, search: "spinach+quesadilla",
               meal: ["lunch/dinner", "snack"], dish: ["main course"], cuisine: ["mexican"], labels: ["Vegetarian"]),
        recipe("22", "Teriyaki Salmon Bowl", ["salmon", "rice", "soy sauce", "avocado", "cucumber", "sesame seeds"], kcal: 1700, minutes: 25, search: "salmon+bowl",
               meal: ["lunch/dinner"], dish: ["main course"], cuisine: ["japanese"], labels: ["Pescatarian", "Dairy-Free", "High-Protein"], servings: 2),
    ]
}
