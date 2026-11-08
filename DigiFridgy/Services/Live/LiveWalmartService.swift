import Foundation
import Security

/// Walmart Affiliate API (walmart.io). Prices are walmart.com prices: one per product, not per store,
/// so the price finder shows them as "Walmart.com price" on every nearby Walmart.
final class LiveWalmartService: WalmartService {
    /// Prices (and "not found") older than this are looked up again.
    static let priceTTL: TimeInterval = 30 * 60
    static let baseURL = "https://developer.api.walmart.com/api-proxy/service/affil/product/v2"

    private let api: APIClient
    private var signer: WalmartSigner?
    private var priceCache: [String: (price: KrogerPrice?, savedAt: Date)] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    var isLive: Bool { Secrets.hasWalmart }

    private func currentSigner() throws -> WalmartSigner {
        if let signer { return signer }
        guard Secrets.hasWalmart else { throw APIError.notConfigured("Walmart") }
        let made = try WalmartSigner(consumerID: Secrets.walmartConsumerID, keyVersion: Secrets.walmartKeyVersion,
                                     privateKey: Secrets.walmartPrivateKey)
        signer = made
        return made
    }

    func price(upc: String?, term: String) async throws -> KrogerPrice? {
        let cacheKey = "\(upc ?? "")|\(term)"
        if let cached = priceCache[cacheKey], Date.now.timeIntervalSince(cached.savedAt) < Self.priceTTL {
            return cached.price
        }
        let result = try await lookUpPrice(upc: upc, term: term)
        priceCache[cacheKey] = (result, .now)
        return result
    }

    /// Exact UPC match first; the name search only runs when walmart.com has no item with that UPC.
    private func lookUpPrice(upc: String?, term: String) async throws -> KrogerPrice? {
        if let upc, let upcA = Self.upcA(from: upc) {
            do {
                let response = try await signedGet(api.url("\(Self.baseURL)/items", query: [("upc", upcA)]))
                if let price = response.firstPrice { return price }
            } catch APIError.badStatus(let code, _) where code == 400 || code == 404 {
                // Unknown UPC: fall through to the name search.
            }
        }
        for candidate in LiveKrogerService.searchTerms(for: term) {
            let url = api.url("\(Self.baseURL)/search", query: [("query", candidate), ("numItems", "5")])
            if let price = try await signedGet(url).firstPrice { return price }
        }
        return nil
    }

    private func signedGet(_ url: URL) async throws -> ItemsResponse {
        let headers = try currentSigner().headers()
        return try await api.get(ItemsResponse.self, from: url, headers: headers)
    }

    /// Walmart looks items up by the 12-digit UPC-A; scanned codes are stored as EAN-13 with a leading 0.
    nonisolated static func upcA(from code: String) -> String? {
        let normalized = Barcode.normalize(code)
        guard normalized.count == 13, normalized.hasPrefix("0") else { return nil }
        return String(normalized.dropFirst())
    }

    struct ItemsResponse: Decodable {
        var items: [Item]?
        struct Item: Decodable {
            var name: String?
            var salePrice: Double?
        }

        /// First item with a real price. `salePrice` is the current walmart.com price.
        var firstPrice: KrogerPrice? {
            for item in items ?? [] {
                if let price = item.salePrice, price > 0 {
                    return KrogerPrice(regular: price, promo: nil, description: item.name)
                }
            }
            return nil
        }
    }
}

/// Signs walmart.io requests: SHA256-with-RSA over "consumerId\ntimestamp\nkeyVersion\n", base64-encoded.
nonisolated struct WalmartSigner {
    enum SignerError: LocalizedError {
        case badKey(String)
        var errorDescription: String? {
            switch self {
            case .badKey(let detail): "Walmart private key couldn't be read (\(detail))."
            }
        }
    }

    let consumerID: String
    let keyVersion: String
    private let key: SecKey

    init(consumerID: String, keyVersion: String, privateKey: String) throws {
        guard let der = Self.rsaDER(from: privateKey) else { throw SignerError.badKey("not base64") }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw SignerError.badKey(error.map { String(describing: $0.takeRetainedValue()) } ?? "not an RSA key")
        }
        self.consumerID = consumerID
        self.keyVersion = keyVersion
        self.key = key
    }

    func headers(at date: Date = .now) throws -> [String: String] {
        let timestamp = String(Int64(date.timeIntervalSince1970 * 1000))
        let message = Data(Self.canonical(consumerID: consumerID, timestamp: timestamp, keyVersion: keyVersion).utf8)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
            throw SignerError.badKey(error.map { String(describing: $0.takeRetainedValue()) } ?? "signing failed")
        }
        return [
            "WM_CONSUMER.ID": consumerID,
            "WM_CONSUMER.INTIMESTAMP": timestamp,
            "WM_SEC.KEY_VERSION": keyVersion,
            "WM_SEC.AUTH_SIGNATURE": (signature as Data).base64EncodedString(),
        ]
    }

    /// The signed headers' values, sorted by header name, each followed by a newline.
    static func canonical(consumerID: String, timestamp: String, keyVersion: String) -> String {
        "\(consumerID)\n\(timestamp)\n\(keyVersion)\n"
    }

    /// PKCS#1 DER from a key given as base64url (the xcconfig form), plain base64, or a PEM;
    /// PKCS#8 ("BEGIN PRIVATE KEY") is unwrapped.
    static func rsaDER(from text: String) -> Data? {
        var body = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
        return pkcs1(fromPKCS8: der) ?? der
    }

    /// PrivateKeyInfo { version, AlgorithmIdentifier { rsaEncryption, NULL }, OCTET STRING { RSAPrivateKey } }
    /// → the inner RSAPrivateKey, or nil when `der` isn't PKCS#8 RSA (e.g. it's already PKCS#1).
    static func pkcs1(fromPKCS8 der: Data) -> Data? {
        let bytes = [UInt8](der)
        func element(at index: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard index + 1 < bytes.count else { return nil }
            var length = Int(bytes[index + 1])
            var start = index + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), start + count <= bytes.count else { return nil }
                length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (bytes[index], start, start + length)
        }
        let rsaEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        guard let outer = element(at: 0), outer.tag == 0x30,
              let version = element(at: outer.start), version.tag == 0x02,
              let algorithm = element(at: version.end), algorithm.tag == 0x30,
              let oid = element(at: algorithm.start), oid.tag == 0x06,
              Array(bytes[oid.start..<oid.end]) == rsaEncryption,
              let key = element(at: algorithm.end), key.tag == 0x04 else { return nil }
        return Data(bytes[key.start..<key.end])
    }
}
