import Foundation

/// `households/{id}`
nonisolated struct Household: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var inviteCode: String
    var memberUids: [String]
    var createdAt: Date

    /// 6 chars, no easily-confused characters (0/O, 1/I/L).
    static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// `users/{uid}`
nonisolated struct UserProfile: Codable, Hashable, Sendable {
    var uid: String
    var householdId: String?
    var displayName: String
    var allergens: [String]
    var dietLabels: [String]
    var searchRadiusMiles: Double
    var zip: String?
    var watchlist: [String]

    init(uid: String, householdId: String? = nil, displayName: String = "",
         allergens: [String] = [], dietLabels: [String] = [],
         searchRadiusMiles: Double = 10, zip: String? = nil, watchlist: [String] = []) {
        self.uid = uid
        self.householdId = householdId
        self.displayName = displayName
        self.allergens = allergens
        self.dietLabels = dietLabels
        self.searchRadiusMiles = searchRadiusMiles
        self.zip = zip
        self.watchlist = watchlist
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        householdId = try c.decodeIfPresent(String.self, forKey: .householdId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        dietLabels = try c.decodeIfPresent([String].self, forKey: .dietLabels) ?? []
        searchRadiusMiles = try c.decodeIfPresent(Double.self, forKey: .searchRadiusMiles) ?? 10
        zip = try c.decodeIfPresent(String.self, forKey: .zip)
        watchlist = try c.decodeIfPresent([String].self, forKey: .watchlist) ?? []
    }

    var allergenSet: Set<Allergen> { Set(allergens.compactMap(Allergen.init(rawValue:))) }
}

/// `households/{hid}/priceHistory/{upc}`
nonisolated struct PriceHistory: Codable, Hashable, Sendable {
    var upc: String
    var lastPrice: Double
    var lastStoreId: String
    var checkedAt: Date
}

/// `households/{hid}/shopping/{id}`
nonisolated struct ShoppingListItem: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var barcode: String?
    var addedAt: Date = .now
    var done: Bool = false
}
