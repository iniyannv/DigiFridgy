import Foundation

/// FDA food enforcement reports via openFDA (no key required).
final class OpenFDARecallService: RecallService {
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
        let url = URL(string: "https://api.fda.gov/food/enforcement.json?search=report_date:%5B\(from)+TO+\(to)%5D&sort=report_date:desc&limit=200")!
        do {
            let response = try await api.get(OpenFDAResponse.self, from: url)
            return response.results.compactMap { $0.toRecall(formatter: formatter) }
        } catch APIError.badStatus(404, _) {
            return []   // openFDA returns 404 when nothing matches
        }
    }
}

nonisolated struct OpenFDAResponse: Decodable, Sendable {
    var results: [Result]

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

/// Matches recalls to fridge items: UPC in recall text first, then brand + name token overlap.
nonisolated struct RecallMatcher: Sendable {
    static let noise: Set<String> = ["the", "and", "with", "for", "organic", "fresh", "natural", "brand",
                                     "inc", "llc", "co", "company", "foods", "food", "oz", "lb", "net", "wt",
                                     "pack", "count", "original", "great", "value"]

    func match(_ item: FridgeItem, in recalls: [Recall]) -> Recall? {
        recalls.first { matches(item, $0) }
    }

    func matches(_ item: FridgeItem, _ recall: Recall) -> Bool {
        if let barcode = item.barcode, upcMatches(barcode, text: recall.codeInfo + " " + recall.productDescription) {
            return true
        }
        let recallTokens = Set(ShelfLifeService.tokenize(recall.productDescription + " " + recall.firm))
        let nameTokens = Set(ShelfLifeService.tokenize(item.name).filter { $0.count >= 3 && !Self.noise.contains($0) })
        guard !nameTokens.isEmpty else { return false }
        let overlap = Double(nameTokens.intersection(recallTokens).count) / Double(nameTokens.count)
        let brandTokens = Set(ShelfLifeService.tokenize(item.brand ?? "").filter { $0.count >= 2 && !Self.noise.contains($0) })
        let brandHit = !brandTokens.isEmpty && brandTokens.isSubset(of: recallTokens)
        return (brandHit && overlap >= 0.5) || (overlap >= 0.8 && nameTokens.count >= 2)
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
