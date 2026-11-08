import Foundation

nonisolated enum ItemSource: String, Codable, Sendable {
    case barcode
    case receipt
}

nonisolated struct RecallFlag: Codable, Hashable, Sendable {
    var recallId: String
    var reason: String
    var date: Date
    var url: String?
}

/// One product line in the household fridge. Stored at `households/{hid}/items/{id}`.
nonisolated struct FridgeItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var barcode: String?
    var name: String
    var brand: String?
    var category: String
    var imageURL: String?
    var count: Int
    var addedAt: Date
    var addedBy: String
    var expiresAt: Date
    var expiryIsEstimated: Bool
    var source: ItemSource
    var nutrition: Nutrition?
    var nutriScore: String?
    var allergens: [String]
    var recallFlag: RecallFlag?
    /// Card purchases synced from the bank backend: what one unit cost and where it was bought.
    var price: Double?
    var store: String?

    init(
        id: String = UUID().uuidString,
        barcode: String? = nil,
        name: String,
        brand: String? = nil,
        category: String,
        imageURL: String? = nil,
        count: Int = 1,
        addedAt: Date = .now,
        addedBy: String = "",
        expiresAt: Date,
        expiryIsEstimated: Bool = true,
        source: ItemSource,
        nutrition: Nutrition? = nil,
        nutriScore: String? = nil,
        allergens: [String] = [],
        recallFlag: RecallFlag? = nil,
        price: Double? = nil,
        store: String? = nil
    ) {
        self.id = id
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.category = category
        self.imageURL = imageURL
        self.count = count
        self.addedAt = addedAt
        self.addedBy = addedBy
        self.expiresAt = expiresAt
        self.expiryIsEstimated = expiryIsEstimated
        self.source = source
        self.nutrition = nutrition
        self.nutriScore = nutriScore
        self.allergens = allergens
        self.recallFlag = recallFlag
        self.price = price
        self.store = store
    }

    // Tolerant decoding: Firestore documents written by older builds may miss fields.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed item"
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ShelfLifeService.unknownCategoryID
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? .now
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy) ?? ""
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt) ?? .now.addingTimeInterval(7 * 86_400)
        expiryIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .expiryIsEstimated) ?? true
        source = try c.decodeIfPresent(ItemSource.self, forKey: .source) ?? .barcode
        nutrition = try c.decodeIfPresent(Nutrition.self, forKey: .nutrition)
        nutriScore = try c.decodeIfPresent(String.self, forKey: .nutriScore)
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        recallFlag = try c.decodeIfPresent(RecallFlag.self, forKey: .recallFlag)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        store = try c.decodeIfPresent(String.self, forKey: .store)
    }
}

nonisolated enum ExpiryUrgency: Sendable {
    case expired, soon, ok
}

nonisolated extension FridgeItem {
    /// Whole days from today until expiry (negative = already expired).
    func daysUntilExpiry(now: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: expiresAt)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    func urgency(now: Date = .now) -> ExpiryUrgency {
        let days = daysUntilExpiry(now: now)
        if days < 0 { return .expired }
        if days <= 2 { return .soon }
        return .ok
    }

    /// Allergens (from `Allergen`) present in this item that the user cares about.
    func allergenHits(for userAllergens: Set<Allergen>) -> [Allergen] {
        Allergen.from(tags: allergens).filter { userAllergens.contains($0) }
    }

    var normalizedBarcode: String? { barcode.map(Barcode.normalize) }

    /// Set by the bank backend for groceries it stocked from a card purchase.
    static let cardPurchaseAddedBy = "bank-purchase"

    var isCardPurchase: Bool { addedBy == Self.cardPurchaseAddedBy }

    /// What the units still in the fridge cost, when the bank knows the price.
    var value: Double? { price.map { $0 * Double(count) } }
}

nonisolated enum Barcode {
    /// Normalizes UPC-A (12 digits) to EAN-13 so the same product always compares equal.
    static func normalize(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count == 12 { return "0" + digits }
        return digits
    }
}
