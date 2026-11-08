import Foundation

/// Kroger public API: OAuth2 client credentials, locations, product prices.
final class LiveKrogerService: KrogerService {
    /// Prices (and "not carried") older than this are looked up again.
    static let priceTTL: TimeInterval = 30 * 60

    private let api: APIClient
    private var token: (value: String, expiresAt: Date)?
    /// One token request shared by every concurrent caller (PriceFinder asks for 5 stores at once).
    private var tokenTask: Task<(value: String, expiresAt: Date), any Error>?
    private var priceCache: [String: (price: KrogerPrice?, savedAt: Date)] = [:]
    private var catalogCache: [String: (found: Bool, savedAt: Date)] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    var isLive: Bool { Secrets.hasKroger }

    private func accessToken() async throws -> String {
        if let token, token.expiresAt > .now.addingTimeInterval(60) { return token.value }
        guard Secrets.hasKroger else { throw APIError.notConfigured("Kroger") }
        if let tokenTask { return try await tokenTask.value.value }
        let api = self.api
        let task = Task { () async throws -> (value: String, expiresAt: Date) in
            var request = URLRequest(url: URL(string: "https://api.kroger.com/v1/connect/oauth2/token")!)
            request.httpMethod = "POST"
            let basic = Data("\(Secrets.krogerClientID):\(Secrets.krogerClientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("grant_type=client_credentials&scope=product.compact".utf8)
            let response = try await api.send(request, as: TokenResponse.self)
            return (response.access_token, .now.addingTimeInterval(TimeInterval(response.expires_in)))
        }
        tokenTask = task
        defer { tokenTask = nil }
        let fresh = try await task.value
        token = fresh
        return fresh.value
    }

    /// GET with the bearer token; a 401 (token revoked or expired early) fetches a new token and retries once.
    private func authorizedGet<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let first = try await accessToken()
        do {
            return try await api.get(type, from: url, headers: ["Authorization": "Bearer \(first)"])
        } catch APIError.badStatus(401, _) {
            if token?.value == first { token = nil }
            let second = try await accessToken()
            return try await api.get(type, from: url, headers: ["Authorization": "Bearer \(second)"])
        }
    }

    func locations(near: Coordinate, radiusMiles: Double, limit: Int) async throws -> [Store] {
        let url = api.url("https://api.kroger.com/v1/locations", query: [
            ("filter.latLong.near", "\(near.latitude),\(near.longitude)"),
            ("filter.radiusInMiles", String(Int(min(max(radiusMiles, 1), 100)))),
            ("filter.limit", String(limit)),
        ])
        let response = try await authorizedGet(LocationsResponse.self, from: url)
        return response.data.compactMap { loc in
            guard let lat = loc.geolocation?.latitude, let lon = loc.geolocation?.longitude else { return nil }
            let coord = Coordinate(latitude: lat, longitude: lon)
            let address = [loc.address?.addressLine1, loc.address?.city, loc.address?.state]
                .compactMap { $0 }.joined(separator: ", ")
            return Store(id: "kroger-\(loc.locationId)", chain: Self.chainName(loc.chain),
                         name: loc.name ?? "Kroger", address: address, coordinate: coord,
                         distanceMiles: near.distanceMiles(to: coord), isKroger: true)
        }
        .sorted { $0.distanceMiles < $1.distanceMiles }
    }

    /// Live price at one store, or nil when that store doesn't carry the product.
    /// A known UPC is matched exactly; the name search is only used when Kroger's catalog has no such UPC.
    func price(upc: String?, term: String, locationId: String) async throws -> KrogerPrice? {
        let rawLocation = locationId.replacingOccurrences(of: "kroger-", with: "")
        let cacheKey = "\(upc ?? "")|\(term)|\(rawLocation)"
        if let cached = priceCache[cacheKey], Date.now.timeIntervalSince(cached.savedAt) < Self.priceTTL {
            return cached.price
        }
        let result = try await lookUpPrice(upc: upc, term: term, location: rawLocation)
        priceCache[cacheKey] = (result, .now)
        return result
    }

    private func lookUpPrice(upc: String?, term: String, location: String) async throws -> KrogerPrice? {
        if let upc, let productId = Self.krogerProductID(fromUPC: upc) {
            let atStore = try await query([("filter.productId", productId)], location: location)
            if let price = atStore.price { return price }
            // Listed at this store without a price, or sold elsewhere by Kroger: this store doesn't have it.
            if atStore.found { return nil }
            if try await isInCatalog(productId: productId) { return nil }
        }
        for candidate in Self.searchTerms(for: term) {
            let match = try await query([("filter.term", candidate)], location: location)
            if let price = match.price { return price }
        }
        return nil
    }

    /// Whether Kroger sells this product anywhere (product lookup without a store filter).
    private func isInCatalog(productId: String) async throws -> Bool {
        if let known = catalogCache[productId], Date.now.timeIntervalSince(known.savedAt) < Self.priceTTL {
            return known.found
        }
        let url = api.url("https://api.kroger.com/v1/products", query: [("filter.productId", productId)])
        let response = try await authorizedGet(ProductsResponse.self, from: url)
        let found = !response.data.isEmpty
        catalogCache[productId] = (found, .now)
        return found
    }

    private func query(_ filter: [(String, String)], location: String) async throws -> (found: Bool, price: KrogerPrice?) {
        let url = api.url("https://api.kroger.com/v1/products",
                          query: filter + [("filter.locationId", location), ("filter.limit", "5")])
        let response = try await authorizedGet(ProductsResponse.self, from: url)
        for product in response.data {
            for item in product.items ?? [] {
                if let regular = item.price?.regular, regular > 0 {
                    let promo = item.price?.promo.flatMap { $0 > 0 ? $0 : nil }
                    return (true, KrogerPrice(regular: regular, promo: promo, description: product.description))
                }
            }
        }
        return (!response.data.isEmpty, nil)
    }

    /// Kroger's term search matches every word, so long label names ("… 20 fl oz bottle") find nothing.
    /// Tries the name without sizes, then its first three and two words.
    nonisolated static func searchTerms(for name: String) -> [String] {
        let units: Set<String> = ["oz", "fl", "lb", "lbs", "g", "kg", "ml", "l", "ct", "count", "pack", "pk",
                                  "gal", "gallon", "qt", "pt", "bottle", "bottles", "can", "cans", "jar", "box", "bag"]
        let words = name
            .replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'&")).inverted)
            .filter { word in
                !word.isEmpty && !units.contains(word.lowercased()) && !word.contains(where: \.isNumber)
            }
        var terms: [String] = []
        for count in [min(words.count, 6), 3, 2] where count > 0 {
            let term = words.prefix(count).joined(separator: " ")
            if term.count >= 3, !terms.contains(term) { terms.append(term) }
        }
        return terms
    }

    /// Kroger product ids are 13 digits: the UPC without its check digit, left-padded with zeros.
    static func krogerProductID(fromUPC upc: String) -> String? {
        let digits = upc.filter(\.isNumber)
        guard digits.count >= 12 else { return nil }
        let withoutCheck = String(digits.dropLast())
        return String(repeating: "0", count: max(0, 13 - withoutCheck.count)) + withoutCheck
    }

    private static func chainName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Kroger" }
        return raw.capitalized
    }

    private struct TokenResponse: Decodable { var access_token: String; var expires_in: Int }

    private struct LocationsResponse: Decodable {
        var data: [Location]
        struct Location: Decodable {
            var locationId: String
            var chain: String?
            var name: String?
            var address: Address?
            var geolocation: Geo?
        }
        struct Address: Decodable { var addressLine1: String?; var city: String?; var state: String? }
        struct Geo: Decodable { var latitude: Double?; var longitude: Double? }
    }

    private struct ProductsResponse: Decodable {
        var data: [Product]
        struct Product: Decodable {
            var description: String?
            var items: [Item]?
        }
        struct Item: Decodable { var price: Price? }
        struct Price: Decodable { var regular: Double?; var promo: Double? }
    }
}
