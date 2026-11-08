import Foundation

/// Traject Data product search: BlueCart API (walmart.com) and RedCircle API (target.com).
/// Each is its own product with its own `api_key`; every successful request costs one credit,
/// so results are cached per term.
final class LiveTrajectSearchService: ProductSearchService {
    nonisolated enum Provider: Sendable {
        case blueCart, redCircle

        var baseURL: String {
            switch self {
            case .blueCart: "https://api.bluecartapi.com/request"
            case .redCircle: "https://api.redcircleapi.com/request"
            }
        }
        var retailer: OtherChain { self == .blueCart ? .walmart : .target }
        var name: String { self == .blueCart ? "BlueCart (Walmart)" : "RedCircle (Target)" }
        var apiKey: String { self == .blueCart ? Secrets.blueCartAPIKey : Secrets.redCircleAPIKey }
    }

    /// Results (including "nothing found") older than this are fetched again.
    static let resultsTTL: TimeInterval = 30 * 60
    static let maxResults = 10

    let provider: Provider
    private let api: APIClient
    private var cache: [String: (products: [RetailProduct], savedAt: Date)] = [:]

    init(_ provider: Provider, api: APIClient = .shared) {
        self.provider = provider
        self.api = api
    }

    var retailer: OtherChain { provider.retailer }
    var isLive: Bool { !provider.apiKey.isEmpty }

    func search(_ term: String) async throws -> [RetailProduct] {
        let cleaned = ProductSearch.cleaned(term)
        guard !cleaned.isEmpty else { return [] }
        let key = cleaned.lowercased()
        if let cached = cache[key], Date.now.timeIntervalSince(cached.savedAt) < Self.resultsTTL {
            return cached.products
        }
        guard isLive else { throw APIError.notConfigured(provider.name) }
        let url = api.url(provider.baseURL, query: [("api_key", provider.apiKey), ("type", "search"),
                                                    ("search_term", cleaned)])
        let products: [RetailProduct]
        do {
            switch provider {
            case .blueCart: products = try await api.get(BlueCartResponse.self, from: url).products
            case .redCircle: products = try await api.get(RedCircleResponse.self, from: url).products
            }
        } catch APIError.badStatus(let code, let body) {
            throw TrajectError(status: code, body: body, provider: provider.name)
        }
        let trimmed = Array(products.prefix(Self.maxResults))
        cache[key] = (trimmed, .now)
        return trimmed
    }

    // MARK: - Responses (internal so tests can decode sample JSON)

    /// BlueCart `type=search`: `search_results[].product / offers.primary / inventory`.
    nonisolated struct BlueCartResponse: Decodable {
        var searchResults: [Lossy<Result>]?

        enum CodingKeys: String, CodingKey { case searchResults = "search_results" }

        struct Result: Decodable {
            var product: Product?
            var offers: Offers?
            var inventory: Inventory?
        }
        struct Product: Decodable {
            var title: String?
            var link: String?
            var itemID: FlexibleString?
            var productID: FlexibleString?
            var rating: Double?
            var ratingsTotal: Int?
            var images: Images?
            enum CodingKeys: String, CodingKey {
                case title, link, rating, images
                case itemID = "item_id", productID = "product_id", ratingsTotal = "ratings_total"
            }
        }
        struct Images: Decodable {
            var primaryImage: String?
            enum CodingKeys: String, CodingKey { case primaryImage = "primary_image" }
        }
        struct Inventory: Decodable {
            var inStock: Bool?
            enum CodingKeys: String, CodingKey { case inStock = "in_stock" }
        }

        var products: [RetailProduct] {
            (searchResults ?? []).compactMap(\.value).compactMap { result in
                guard let product = result.product,
                      let title = product.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
                let id = product.itemID?.value ?? product.productID?.value ?? product.link ?? title
                return RetailProduct(id: "walmart-\(id)", retailer: .walmart, title: title,
                                     price: result.offers?.primary?.price,
                                     imageURL: product.images?.primaryImage.flatMap(URL.init(string:)),
                                     productURL: product.link.flatMap(URL.init(string:)),
                                     rating: product.rating, ratingsTotal: product.ratingsTotal,
                                     inStock: result.inventory?.inStock)
            }
        }
    }

    /// RedCircle `type=search`: `search_results[].product / offers.primary`. `main_image` is a plain URL string.
    nonisolated struct RedCircleResponse: Decodable {
        var searchResults: [Lossy<Result>]?

        enum CodingKeys: String, CodingKey { case searchResults = "search_results" }

        struct Result: Decodable {
            var product: Product?
            var offers: Offers?
        }
        struct Product: Decodable {
            var title: String?
            var link: String?
            var tcin: FlexibleString?
            var rating: Double?
            var ratingsTotal: Int?
            var mainImage: String?
            enum CodingKeys: String, CodingKey {
                case title, link, tcin, rating
                case ratingsTotal = "ratings_total", mainImage = "main_image"
            }
        }

        var products: [RetailProduct] {
            (searchResults ?? []).compactMap(\.value).compactMap { result in
                guard let product = result.product,
                      let title = product.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
                let id = product.tcin?.value ?? product.link ?? title
                return RetailProduct(id: "target-\(id)", retailer: .target, title: title,
                                     price: result.offers?.primary?.price,
                                     imageURL: product.mainImage.flatMap(URL.init(string:)),
                                     productURL: product.link.flatMap(URL.init(string:)),
                                     rating: product.rating, ratingsTotal: product.ratingsTotal, inStock: nil)
            }
        }
    }

    nonisolated struct Offers: Decodable {
        var primary: Primary?
        struct Primary: Decodable { var price: Double? }
    }
}

/// Traject status codes turned into messages a shopper can act on.
nonisolated struct TrajectError: LocalizedError {
    var status: Int
    var body: String
    var provider: String

    var errorDescription: String? {
        switch status {
        case 401: "\(provider) rejected the API key."
        case 402: "\(provider) is out of search credits."
        case 429: "\(provider) is busy right now. Try again in a minute."
        case 503: "\(provider) couldn't read the store's page just now. Try again later."
        default: "\(provider) search failed. Try again in a minute."
        }
    }

    var failureReason: String? { "Server returned \(status). \(body.prefix(140))" }
}

/// Decodes an element, or nil when that one element has an unexpected shape, so one odd result
/// doesn't throw away the whole page.
nonisolated struct Lossy<Wrapped: Decodable>: Decodable {
    var value: Wrapped?
    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// An ID that may arrive as a JSON string or number.
nonisolated struct FlexibleString: Decodable, Hashable {
    var value: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else {
            value = String(try container.decode(Double.self))
        }
    }
}
