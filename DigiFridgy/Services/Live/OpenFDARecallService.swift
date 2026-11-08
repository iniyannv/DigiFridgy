import Foundation

/// FDA food enforcement reports via openFDA (no key required). FDA-regulated foods only: USDA FSIS
/// (meat, poultry, egg products) has no public JSON API an app can call, so those recalls aren't covered.
final class OpenFDARecallService: RecallService {
    /// openFDA's maximum page size.
    static let pageSize = 1000
    /// openFDA rejects `skip` past 25,000; 90 days of food recalls is far below that.
    static let maxPages = 10

    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func recentRecalls(days: Int) async throws -> [Recall] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let from = formatter.string(from: Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now)
        let to = formatter.string(from: .now)
        var recalls: [Recall] = []
        for page in 0..<Self.maxPages {
            let url = URL(string: "https://api.fda.gov/food/enforcement.json?search=report_date:%5B\(from)+TO+\(to)%5D&sort=report_date:desc&limit=\(Self.pageSize)&skip=\(page * Self.pageSize)")!
            let response: OpenFDAResponse
            do {
                response = try await api.get(OpenFDAResponse.self, from: url)
            } catch APIError.badStatus(404, _) {
                break   // openFDA returns 404 when nothing (more) matches
            }
            recalls += response.results.compactMap { $0.toRecall(formatter: formatter) }
            let total = response.meta?.results?.total ?? 0
            if response.results.count < Self.pageSize || recalls.count >= total { break }
        }
        return recalls
    }
}

nonisolated struct OpenFDAResponse: Decodable, Sendable {
    var meta: Meta?
    var results: [Result]

    struct Meta: Decodable, Sendable {
        var results: Page?
        struct Page: Decodable, Sendable { var skip: Int?; var limit: Int?; var total: Int? }
    }

    struct Result: Decodable, Sendable {
        var recall_number: String?
        var reason_for_recall: String?
        var product_description: String?
        var code_info: String?
        var recalling_firm: String?
        var report_date: String?
        var recall_initiation_date: String?
        var classification: String?

        func toRecall(formatter: DateFormatter) -> Recall? {
            guard let id = recall_number else { return nil }
            let date = (report_date ?? recall_initiation_date).flatMap(formatter.date(from:)) ?? .now
            let firm = recalling_firm ?? ""
            let search = firm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return Recall(
                id: id,
                reason: reason_for_recall ?? "See FDA notice",
                productDescription: product_description ?? "",
                codeInfo: code_info ?? "",
                firm: firm,
                date: date,
                classification: classification,
                url: "https://www.fda.gov/safety/recalls-market-withdrawals-safety-alerts?search_api_fulltext=\(search)"
            )
        }
    }
}

/// A recall that applies to a fridge item, and how sure the match is.
nonisolated struct RecallHit: Sendable {
    var recall: Recall
    var confidence: RecallConfidence
    var flag: RecallFlag { recall.flag(confidence: confidence) }
}

/// Matches recalls to fridge items: UPC in recall text first, then brand + name token overlap.
/// A match on the product name alone is only a *possible* recall (the brand can't be checked).
nonisolated struct RecallMatcher: Sendable {
    static let noise: Set<String> = ["the", "and", "with", "for", "organic", "fresh", "natural", "brand",
                                     "inc", "llc", "co", "company", "foods", "food", "oz", "lb", "net", "wt",
                                     "pack", "count", "original", "great", "value"]
    /// A recall announced longer than this before the item was bought is about older stock.
    static let minimumWindowDays = 14

    var shelfLife: ShelfLifeService = .shared

    func match(_ item: FridgeItem, in recalls: [Recall]) -> RecallHit? {
        let candidates = recalls.filter { !item.dismissedRecallIDs.contains($0.id) && !isTooOld($0, for: item) }
        // Prefer a confirmed match over a name-only one.
        var possible: RecallHit?
        for recall in candidates {
            switch confidence(item, recall) {
            case .confirmed?: return RecallHit(recall: recall, confidence: .confirmed)
            case .possible?: if possible == nil { possible = RecallHit(recall: recall, confidence: .possible) }
            case nil: continue
            }
        }
        return possible
    }

    func matches(_ item: FridgeItem, _ recall: Recall) -> Bool {
        confidence(item, recall) != nil
    }

    /// Recall dated before the item was bought minus its shelf-life window (at least two weeks).
    func isTooOld(_ recall: Recall, for item: FridgeItem) -> Bool {
        let window = max(shelfLife.fridgeDays(for: item.category), Self.minimumWindowDays)
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -window, to: item.addedAt) else { return false }
        return recall.date < cutoff
    }

    func confidence(_ item: FridgeItem, _ recall: Recall) -> RecallConfidence? {
        if let barcode = item.barcode, upcMatches(barcode, text: recall.codeInfo + " " + recall.productDescription) {
            return .confirmed
        }
        let recallTokens = Set(ShelfLifeService.tokenize(recall.productDescription + " " + recall.firm))
        let nameTokens = Set(ShelfLifeService.tokenize(item.name).filter { $0.count >= 3 && !Self.noise.contains($0) })
        guard !nameTokens.isEmpty else { return nil }
        let overlap = Double(nameTokens.intersection(recallTokens).count) / Double(nameTokens.count)
        let brandTokens = Set(ShelfLifeService.tokenize(item.brand ?? "").filter { $0.count >= 2 && !Self.noise.contains($0) })
        // Single-word names ("Spinach") are fine when the brand matches too.
        if !brandTokens.isEmpty && brandTokens.isSubset(of: recallTokens) && overlap >= 0.5 { return .confirmed }
        if overlap >= 0.8 && nameTokens.count >= 2 {
            // Name only: a different brand's product would match just as well.
            return .possible
        }
        return nil
    }

    /// Recall notices write UPCs as "0 78742 35186 5" or "078742-351865"; compare the 11-digit core.
    func upcMatches(_ barcode: String, text: String) -> Bool {
        let digits = Barcode.normalize(barcode)
        guard digits.count >= 12 else { return false }
        let core = digits.hasPrefix("0") ? String(digits.dropFirst().dropLast()) : String(digits.dropLast())
        guard core.count >= 10 else { return false }
        let pattern = /\d[\d\s\-]{8,20}\d/
        for run in text.matches(of: pattern) {
            let runDigits = String(run.output).filter(\.isNumber)
            if runDigits.contains(core) { return true }
        }
        return false
    }
}
