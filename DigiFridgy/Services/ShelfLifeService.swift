import Foundation

nonisolated struct FoodCategory: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var fridgeDays: Int
    var searchTerm: String
    var baselinePrice: Double
    var keywords: [String]
    /// Typical Nutri-Score (a–e) of a plain product in this category; nil when it varies too much to guess.
    var nutriScore: String?
}

/// A Nutri-Score to show: the product's own (from Open Food Facts) or its food type's typical grade.
nonisolated struct NutriScoreGrade: Equatable, Sendable {
    var grade: String
    var isEstimated: Bool
}

/// Estimates expiry from food category using the bundled `shelf_life.json`
/// (refrigerator days, approximating USDA FoodKeeper guidance).
nonisolated final class ShelfLifeService: Sendable {
    static let unknownCategoryID = "other"
    static let shared = ShelfLifeService()

    let categories: [FoodCategory]
    let defaultDays: Int
    private let byID: [String: FoodCategory]

    init(bundle: Bundle = .main) {
        struct File: Decodable { var defaultDays: Int; var categories: [FoodCategory] }
        if let url = bundle.url(forResource: "shelf_life", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            categories = file.categories
            defaultDays = file.defaultDays
        } else {
            categories = []
            defaultDays = 7
        }
        byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    init(categories: [FoodCategory], defaultDays: Int = 7) {
        self.categories = categories
        self.defaultDays = defaultDays
        byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    func category(id: String) -> FoodCategory? { byID[id] }

    func displayName(for id: String) -> String { byID[id]?.name ?? "Other" }

    func fridgeDays(for id: String) -> Int { byID[id]?.fridgeDays ?? defaultDays }

    /// The item's scanned grade, else the typical grade for its category (receipts, card purchases, iMessage).
    func nutriScore(for item: FridgeItem) -> NutriScoreGrade? {
        if let grade = item.nutriScore?.lowercased(), "abcde".contains(grade), grade.count == 1 {
            return NutriScoreGrade(grade: grade, isEstimated: false)
        }
        return byID[item.category]?.nutriScore.map { NutriScoreGrade(grade: $0, isEstimated: true) }
    }

    /// Start of the day `fridgeDays` after `date` (expiry is a calendar day, not an instant).
    func estimatedExpiry(categoryID: String, from date: Date = .now, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: fridgeDays(for: categoryID), to: start) ?? start
    }

    /// Maps Open Food Facts `categories_tags` (ordered general → specific) to a category id.
    func categoryID(forOFFTags tags: [String]) -> String {
        for tag in tags.reversed() {
            let text = tag.split(separator: ":").last.map(String.init) ?? tag
            if let match = bestMatch(in: text.replacingOccurrences(of: "-", with: " ")) {
                return match
            }
        }
        return Self.unknownCategoryID
    }

    /// Maps a free-text product name ("Organic Baby Spinach 5oz") to a category id.
    func categoryID(forName name: String) -> String {
        bestMatch(in: name) ?? Self.unknownCategoryID
    }

    /// The words of a product name that matched a category keyword ("Boneless Chicken Breast" → "chicken breast").
    func matchedKeyword(in name: String, categoryID: String) -> String? {
        guard let category = byID[categoryID] else { return nil }
        return bestKeyword(in: name, among: [category])?.keyword
    }

    /// Picks the keyword with the most words; ties go to the match closest to the end
    /// of the phrase (the head noun in English: "blueberry yogurt" → yogurt).
    private func bestMatch(in text: String) -> String? {
        bestKeyword(in: text, among: categories)?.id
    }

    private func bestKeyword(in text: String, among candidates: [FoodCategory]) -> (id: String, keyword: String)? {
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return nil }
        var best: (id: String, keyword: String, words: Int, end: Int)?
        for category in candidates {
            for keyword in category.keywords {
                let kw = Self.tokenize(keyword)
                guard !kw.isEmpty, kw.count <= tokens.count else { continue }
                for start in 0...(tokens.count - kw.count) {
                    let matches = kw.indices.allSatisfy { Self.wordMatches(tokens[start + $0], kw[$0]) }
                    guard matches else { continue }
                    let end = start + kw.count
                    if best == nil || kw.count > best!.words || (kw.count == best!.words && end > best!.end) {
                        best = (category.id, tokens[start..<end].joined(separator: " "), kw.count, end)
                    }
                }
            }
        }
        return best.map { ($0.id, $0.keyword) }
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "%")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func wordMatches(_ token: String, _ keyword: String) -> Bool {
        if token == keyword { return true }
        if token == keyword + "s" || token == keyword + "es" { return true }
        if keyword.hasSuffix("y"), token == keyword.dropLast() + "ies" { return true }
        return false
    }
}
