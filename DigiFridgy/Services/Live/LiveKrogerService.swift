import Foundation

/// Kroger public API: OAuth2 client credentials, locations, product prices.
final class LiveKrogerService: KrogerService {
    private let api: APIClient
    private var token: (value: String, expiresAt: Date)?
    private var priceCache: [String: KrogerPrice?] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    var isLive: Bool { Secrets.hasKroger }

    private func accessToken() async throws -> String {
        if let token, token.expiresAt > .now.addingTimeInterval(60) { return token.value }
        guard Secrets.hasKroger else { throw APIError.notConfigured("Kroger") }
        var request = URLRequest(url: URL(string: "https://api.kroger.com/v1/connect/oauth2/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(Secrets.krogerClientID):\(Secrets.krogerClientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials&scope=product.compact".utf8)
        let response = try await api.send(request, as: TokenResponse.self)
        token = (response.access_token, .now.addingTimeInterval(TimeInterval(response.expires_in)))
        return response.access_token
    }

    func locations(near: Coordinate, radiusMiles: Double, limit: Int) async throws -> [Store] {
        let token = try await accessToken()
        let url = api.url("https://api.kroger.com/v1/locations", query: [
            ("filter.latLong.near", "\(near.latitude),\(near.longitude)"),
            ("filter.radiusInMiles", String(Int(min(max(radiusMiles, 1), 100)))),
            ("filter.limit", String(limit)),
        ])
        let response = try await api.get(LocationsResponse.self, from: url, headers: ["Authorization": "Bearer \(token)"])
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

    func price(upc: String?, term: String, locationId: String) async throws -> KrogerPrice? {
        let rawLocation = locationId.replacingOccurrences(of: "kroger-", with: "")
        let cacheKey = "\(upc ?? "")|\(term)|\(rawLocation)"
        if let cached = priceCache[cacheKey] { return cached }
        let token = try await accessToken()
        var result: KrogerPrice?
        if let upc, let productId = Self.krogerProductID(fromUPC: upc) {
            result = try await query([("filter.productId", productId)], location: rawLocation, token: token)
        }
        if result == nil {
            let cleanTerm = String(term.prefix(60))
            if cleanTerm.count >= 3 {
                result = try await query([("filter.term", cleanTerm)], location: rawLocation, token: token)
            }
        }
        priceCache[cacheKey] = result
        return result
    }

    private func query(_ filter: [(String, String)], location: String, token: String) async throws -> KrogerPrice? {
        let url = api.url("https://api.kroger.com/v1/products",
                          query: filter + [("filter.locationId", location), ("filter.limit", "5")])
        let response = try await api.get(ProductsResponse.self, from: url, headers: ["Authorization": "Bearer \(token)"])
        for product in response.data {
            for item in product.items ?? [] {
                if let regular = item.price?.regular, regular > 0 {
                    let promo = item.price?.promo.flatMap { $0 > 0 ? $0 : nil }
                    return KrogerPrice(regular: regular, promo: promo, description: product.description)
                }
            }
        }
        return nil
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
