import Foundation

nonisolated enum ItemSource: String, Codable, Sendable {
    case barcode
    case receipt
}

/// How sure the matcher is that a recall is about this exact product.
nonisolated enum RecallConfidence: String, Codable, Sendable {
    /// UPC in the notice, or brand + product name.
    case confirmed
    /// Product name only (no brand or UPC to compare): "Possible recall: check the brand".
    case possible
}

nonisolated struct RecallFlag: Codable, Hashable, Sendable {
    var recallId: String
    var reason: String
    var date: Date
    var url: String?
    var confidence: RecallConfidence = .confirmed

    init(recallId: String, reason: String, date: Date, url: String?, confidence: RecallConfidence = .confirmed) {
        self.recallId = recallId
        self.reason = reason
        self.date = date
        self.url = url
        self.confidence = confidence
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recallId = try c.decode(String.self, forKey: .recallId)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "See FDA notice"
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .now
        url = try c.decodeIfPresent(String.self, forKey: .url)
        // Flags written before confidence existed came from the strict matcher.
        confidence = try c.decodeIfPresent(RecallConfidence.self, forKey: .confidence) ?? .confirmed
    }

    var isPossible: Bool { confidence == .possible }
    /// "Recall" or "Possible recall: check the brand".
    var title: String { isPossible ? "Possible recall: check the brand" : "Recalled — do not eat" }
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
    /// The expiry *day* (printed or estimated). Stored as a calendar date ("yyyy-MM-dd" in `expiryDate`),
    /// so it shows the same day in every time zone; in memory it is the start of that day locally.
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
    /// Recalls the user said aren't about this product ("Not my product"); never flagged again.
    var dismissedRecallIDs: [String]

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
        store: String? = nil,
        dismissedRecallIDs: [String] = []
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
        self.dismissedRecallIDs = dismissedRecallIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, barcode, name, brand, category, imageURL, count, addedAt, addedBy, expiresAt, expiryDate
        case expiryIsEstimated, source, nutrition, nutriScore, allergens, recallFlag, price, store, dismissedRecallIDs
    }

    /// Set a `Calendar` here in an encoder's or decoder's `userInfo` to read/write expiry days in its time zone
    /// (defaults to `Calendar.current`).
    static let calendarKey = CodingUserInfoKey(rawValue: "digifridgy.calendar")!

    // Tolerant decoding: documents written by older builds may miss fields.
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
        let calendar = decoder.userInfo[Self.calendarKey] as? Calendar ?? .current
        if let day = try c.decodeIfPresent(String.self, forKey: .expiryDate), let date = CalendarDay.date(from: day, calendar: calendar) {
            expiresAt = date
        } else if let legacy = try c.decodeIfPresent(Date.self, forKey: .expiresAt) {
            // Older builds and the bank backend write an instant (ms): use the local day it falls on.
            expiresAt = calendar.startOfDay(for: legacy)
        } else {
            expiresAt = calendar.startOfDay(for: .now.addingTimeInterval(7 * 86_400))
        }
        expiryIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .expiryIsEstimated) ?? true
        source = try c.decodeIfPresent(ItemSource.self, forKey: .source) ?? .barcode
        nutrition = try c.decodeIfPresent(Nutrition.self, forKey: .nutrition)
        nutriScore = try c.decodeIfPresent(String.self, forKey: .nutriScore)
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        recallFlag = try c.decodeIfPresent(RecallFlag.self, forKey: .recallFlag)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        store = try c.decodeIfPresent(String.self, forKey: .store)
        dismissedRecallIDs = try c.decodeIfPresent([String].self, forKey: .dismissedRecallIDs) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        let calendar = encoder.userInfo[Self.calendarKey] as? Calendar ?? .current
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(barcode, forKey: .barcode)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encode(count, forKey: .count)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(addedBy, forKey: .addedBy)
        try c.encode(CalendarDay.string(from: expiresAt, calendar: calendar), forKey: .expiryDate)
        // Kept for older builds and the bank backend, which read an instant: noon UTC on the same day.
        try c.encode(CalendarDay.noonUTC(of: expiresAt, calendar: calendar), forKey: .expiresAt)
        try c.encode(expiryIsEstimated, forKey: .expiryIsEstimated)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(nutrition, forKey: .nutrition)
        try c.encodeIfPresent(nutriScore, forKey: .nutriScore)
        try c.encode(allergens, forKey: .allergens)
        try c.encodeIfPresent(recallFlag, forKey: .recallFlag)
        try c.encodeIfPresent(price, forKey: .price)
        try c.encodeIfPresent(store, forKey: .store)
        if !dismissedRecallIDs.isEmpty { try c.encode(dismissedRecallIDs, forKey: .dismissedRecallIDs) }
    }
}

/// A calendar day ("2026-11-07") independent of time zone.
nonisolated enum CalendarDay {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Start of that day in the calendar's time zone.
    static func date(from string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Noon UTC on the date's local calendar day: readers within ±12 h of UTC land on the same day.
    static func noonUTC(of date: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? date
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

    /// The one expiry phrase used everywhere text mentions expiry: "Est. exp. in 2d", "Exp. tomorrow",
    /// "Est. expired yesterday". Estimated dates always start with "Est.".
    func expiryLabel(now: Date = .now, calendar: Calendar = .current) -> String {
        let days = daysUntilExpiry(now: now, calendar: calendar)
        let text: String
        switch days {
        case ..<(-1): text = "expired \(-days)d ago"
        case -1: text = "expired yesterday"
        case 0: text = "exp. today"
        case 1: text = "exp. tomorrow"
        default: text = "exp. in \(days)d"
        }
        return expiryIsEstimated ? "Est. " + text : text.prefix(1).uppercased() + text.dropFirst()
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
    /// Normalizes UPC-A (12 digits) and UPC-E (8 digits, zero-suppressed) to EAN-13 so the same product
    /// always compares equal. EAN-8 codes stay as they are.
    static func normalize(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count == 12 { return "0" + digits }
        if digits.count == 8, let upcA = expandUPCE(digits) { return "0" + upcA }
        return digits
    }

    /// UPC-E (number system 0/1 + 6 digits + check) → UPC-A, or nil when it isn't a valid UPC-E
    /// (then it is treated as EAN-8).
    static func expandUPCE(_ code: String) -> String? {
        let d = code.compactMap(\.wholeNumberValue)
        guard d.count == 8, d[0] == 0 || d[0] == 1 else { return nil }
        let ns = d[0], m = Array(d[1...6]), check = d[7]
        let body: [Int]
        switch m[5] {
        case 0, 1, 2: body = [ns, m[0], m[1], m[5], 0, 0, 0, 0, m[2], m[3], m[4]]
        case 3: body = [ns, m[0], m[1], m[2], 0, 0, 0, 0, 0, m[3], m[4]]
        case 4: body = [ns, m[0], m[1], m[2], m[3], 0, 0, 0, 0, 0, m[4]]
        default: body = [ns, m[0], m[1], m[2], m[3], m[4], 0, 0, 0, 0, m[5]]
        }
        guard upcCheckDigit(body) == check else { return nil }
        return (body + [check]).map(String.init).joined()
    }

    /// Check digit for the first 11 digits of a UPC-A.
    static func upcCheckDigit(_ body: [Int]) -> Int {
        let odd = stride(from: 0, to: body.count, by: 2).reduce(0) { $0 + body[$1] }
        let even = stride(from: 1, to: body.count, by: 2).reduce(0) { $0 + body[$1] }
        return (10 - (odd * 3 + even) % 10) % 10
    }
}
