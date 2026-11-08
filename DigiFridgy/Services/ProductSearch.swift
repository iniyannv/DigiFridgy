import Foundation

/// One product from a retailer's online search (walmart.com / target.com), from Traject Data or a sample.
nonisolated struct RetailProduct: Identifiable, Hashable, Sendable {
    /// "walmart-<item_id>" / "target-<tcin>".
    var id: String
    var retailer: OtherChain
    var title: String
    var price: Double?
    var imageURL: URL?
    var productURL: URL?
    var rating: Double?
    var ratingsTotal: Int?
    var inStock: Bool?
}

/// Free-text product search at one online retailer.
protocol ProductSearchService: AnyObject, Sendable {
    var retailer: OtherChain { get }
    /// False = sample results.
    var isLive: Bool { get }
    func search(_ term: String) async throws -> [RetailProduct]
}

/// Searches every retailer at once; one retailer failing doesn't hide the others.
enum ProductSearch {
    typealias Outcome = Result<[RetailProduct], any Error>

    static func cleaned(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load(term: String, walmart: any ProductSearchService,
                     target: any ProductSearchService) async -> (walmart: Outcome, target: Outcome) {
        async let walmartResult = outcome { try await walmart.search(term) }
        async let targetResult = outcome { try await target.search(term) }
        return await (walmartResult, targetResult)
    }

    private static func outcome(_ body: () async throws -> [RetailProduct]) async -> Outcome {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

/// Offline sample results: a few store-brand style products with stable, made-up prices.
final class MockProductSearchService: ProductSearchService {
    let retailer: OtherChain
    var isLive: Bool { false }

    init(retailer: OtherChain) {
        self.retailer = retailer
    }

    func search(_ term: String) async throws -> [RetailProduct] {
        let name = ProductSearch.cleaned(term).capitalized
        guard !name.isEmpty else { return [] }
        let brands = retailer == .target ? ["Good & Gather", "Market Pantry", "Favorite Day"]
                                         : ["Great Value", "Marketside", "Sam's Choice"]
        return brands.enumerated().map { index, brand in
            let seed = MockPriceService.fnv1a("\(retailer.rawValue)|\(name)|\(index)")
            let price = MockPriceService.retailRound(1.5 + Double(seed % 600) / 100)
            return RetailProduct(id: "\(retailer.rawValue.lowercased())-sample-\(index)", retailer: retailer,
                                 title: "\(brand) \(name)", price: price, imageURL: nil, productURL: nil,
                                 rating: 3.8 + Double(seed % 12) / 10, ratingsTotal: Int(seed % 900) + 12,
                                 inStock: true)
        }
    }
}
