import Foundation

/// Per-serving (or per-100g when serving size is unknown) nutrition snapshot taken at scan time.
nonisolated struct Nutrition: Codable, Hashable, Sendable {
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var sugar: Double?
    var sodium: Double?   // milligrams
    var fiber: Double?
    var servingSize: String?

    var isEmpty: Bool {
        [kcal, protein, carbs, fat, sugar, sodium, fiber].allSatisfy { $0 == nil }
    }
}

/// The nine major US allergens the app tracks.
nonisolated enum Allergen: String, CaseIterable, Codable, Identifiable, Sendable {
    case milk, eggs, peanuts, treeNuts, soy, wheat, fish, shellfish, sesame

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .milk: "Milk"
        case .eggs: "Eggs"
        case .peanuts: "Peanuts"
        case .treeNuts: "Tree nuts"
        case .soy: "Soy"
        case .wheat: "Wheat / Gluten"
        case .fish: "Fish"
        case .shellfish: "Shellfish"
        case .sesame: "Sesame"
        }
    }

    var symbol: String {
        switch self {
        case .milk: "drop.fill"
        case .eggs: "oval.portrait.fill"
        case .peanuts, .treeNuts: "leaf.fill"
        case .soy: "circle.grid.2x2.fill"
        case .wheat: "laurel.leading"
        case .fish: "fish.fill"
        case .shellfish: "tortoise.fill"
        case .sesame: "circle.dotted"
        }
    }

    /// Edamam `health=` label that excludes this allergen.
    var edamamHealthLabel: String {
        switch self {
        case .milk: "dairy-free"
        case .eggs: "egg-free"
        case .peanuts: "peanut-free"
        case .treeNuts: "tree-nut-free"
        case .soy: "soy-free"
        case .wheat: "gluten-free"
        case .fish: "fish-free"
        case .shellfish: "shellfish-free"
        case .sesame: "sesame-free"
        }
    }

    /// Open Food Facts `allergens_tags` values that map to this allergen.
    var offTags: [String] {
        switch self {
        case .milk: ["en:milk", "en:lactose", "en:dairy"]
        case .eggs: ["en:eggs", "en:egg"]
        case .peanuts: ["en:peanuts", "en:peanut"]
        case .treeNuts: ["en:nuts", "en:tree-nuts", "en:almonds", "en:hazelnuts", "en:walnuts", "en:cashew-nuts", "en:pecan-nuts"]
        case .soy: ["en:soybeans", "en:soy", "en:soya"]
        case .wheat: ["en:gluten", "en:wheat"]
        case .fish: ["en:fish"]
        case .shellfish: ["en:crustaceans", "en:molluscs", "en:shellfish"]
        case .sesame: ["en:sesame-seeds", "en:sesame"]
        }
    }

    /// Maps OFF tags (or our own stored raw values) to allergens.
    static func from(tags: [String]) -> [Allergen] {
        let set = Set(tags.map { $0.lowercased() })
        return allCases.filter { a in set.contains(a.rawValue.lowercased()) || a.offTags.contains(where: set.contains) }
    }

    /// Allergens implied by a food category when no label data exists (receipt items).
    static func implied(byCategory category: String) -> [Allergen] {
        switch category {
        case "milk", "cream", "butter", "yogurt", "sour_cream", "cottage_cheese", "cream_cheese",
             "hard_cheese", "soft_cheese", "shredded_cheese", "ice_cream":
            [.milk]
        case "eggs": [.eggs]
        case "bread", "tortillas", "dough", "fresh_pasta", "pizza": [.wheat]
        case "fish", "smoked_fish": [.fish]
        case "shellfish": [.shellfish]
        case "tofu", "plant_milk": [.soy]
        case "hummus": [.sesame]
        default: []
        }
    }
}
