import Testing
import Foundation
import Security
@testable import DigiFridgy

struct WalmartSignerTests {
    private static func makeKey() throws -> (privateKey: SecKey, pkcs1: Data) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let der = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        return (key, der)
    }

    /// The xcconfig form: base64url without padding.
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        if count < 0x100 { return [0x81, UInt8(count)] }
        return [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
    }

    private static func pkcs8(wrapping pkcs1: Data) -> Data {
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let inner: [UInt8] = [0x02, 0x01, 0x00] + algorithm + [0x04] + derLength(pkcs1.count) + [UInt8](pkcs1)
        return Data([0x30] + derLength(inner.count) + inner)
    }

    private static func verify(_ headers: [String: String], with privateKey: SecKey) throws -> Bool {
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let consumer = try #require(headers["WM_CONSUMER.ID"])
        let timestamp = try #require(headers["WM_CONSUMER.INTIMESTAMP"])
        let version = try #require(headers["WM_SEC.KEY_VERSION"])
        let encoded = try #require(headers["WM_SEC.AUTH_SIGNATURE"])
        let message = WalmartSigner.canonical(consumerID: consumer, timestamp: timestamp, keyVersion: version)
        let signature = try #require(Data(base64Encoded: encoded))
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData,
                                     signature as CFData, nil)
    }

    @Test func signsTheCanonicalHeaderString() throws {
        let (key, pkcs1) = try Self.makeKey()
        let signer = try WalmartSigner(consumerID: "consumer-123", keyVersion: "1", privateKey: Self.base64url(pkcs1))
        let headers = try signer.headers(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(headers["WM_CONSUMER.ID"] == "consumer-123")
        #expect(headers["WM_CONSUMER.INTIMESTAMP"] == "1700000000000")
        #expect(headers["WM_SEC.KEY_VERSION"] == "1")
        #expect(try Self.verify(headers, with: key))
    }

    @Test func readsPKCS8AndPEMKeys() throws {
        let (key, pkcs1) = try Self.makeKey()
        let pkcs8 = Self.pkcs8(wrapping: pkcs1)
        #expect(WalmartSigner.pkcs1(fromPKCS8: pkcs8) == pkcs1)
        #expect(WalmartSigner.pkcs1(fromPKCS8: pkcs1) == nil)

        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString(options: .lineLength64Characters)
            + "\n-----END PRIVATE KEY-----\n"
        let signer = try WalmartSigner(consumerID: "c", keyVersion: "2", privateKey: pem)
        let headers = try signer.headers()
        #expect(try Self.verify(headers, with: key))
    }

    @Test func rejectsGarbageKeys() {
        #expect(throws: (any Error).self) { try WalmartSigner(consumerID: "c", keyVersion: "1", privateKey: "not a key!") }
        #expect(throws: (any Error).self) { try WalmartSigner(consumerID: "c", keyVersion: "1", privateKey: "aGVsbG8") }
    }
}

struct WalmartParsingTests {
    @Test func upcAFromScannedCodes() {
        #expect(LiveWalmartService.upcA(from: "0078742351865") == "078742351865")
        #expect(LiveWalmartService.upcA(from: "078742351865") == "078742351865")
        #expect(LiveWalmartService.upcA(from: "5000112637922") == nil)   // EAN-13 that isn't a UPC
        #expect(LiveWalmartService.upcA(from: "1234") == nil)
    }

    @Test func firstPricedItemWins() throws {
        let json = #"""
        {"items":[{"itemId":1,"name":"No price"},{"itemId":2,"name":"Great Value Whole Milk, 1 gal","salePrice":3.42,
          "msrp":3.98,"upc":"078742351865","stock":"Available"}]}
        """#
        let response = try JSONDecoder().decode(LiveWalmartService.ItemsResponse.self, from: Data(json.utf8))
        let price = try #require(response.firstPrice)
        #expect(price.regular == 3.42)
        #expect(price.promo == nil)
        #expect(price.description == "Great Value Whole Milk, 1 gal")
        let empty = try JSONDecoder().decode(LiveWalmartService.ItemsResponse.self, from: Data(#"{"query":"x"}"#.utf8))
        #expect(empty.firstPrice == nil)
    }
}

private final class StubWalmart: WalmartService {
    let result: Result<KrogerPrice?, any Error>
    init(_ result: Result<KrogerPrice?, any Error>) { self.result = result }
    let isLive = true
    func price(upc: String?, term: String) async throws -> KrogerPrice? { try result.get() }
}

@MainActor
struct WalmartPriceFinderTests {
    private func findQuotes(walmart: any WalmartService) async throws -> [PriceQuote] {
        let mock = AppServices.mock()
        let services = AppServices(
            isMock: true, auth: mock.auth, repository: mock.repository, products: mock.products,
            recipes: mock.recipes, recalls: mock.recalls, kroger: mock.kroger, storeSearch: mock.storeSearch,
            location: mock.location, ocr: mock.ocr, normalizer: mock.normalizer, notifications: mock.notifications,
            walmart: walmart)
        return try await PriceFinder(services: services).quotes(
            name: "Whole Milk", upc: "0078742351865", categoryID: "milk", near: .demoFallback, radiusMiles: 10).quotes
    }

    private func walmartQuotes(_ quotes: [PriceQuote]) -> [PriceQuote] {
        quotes.filter { $0.store.chain == OtherChain.walmart.rawValue }
    }

    @Test func walmartStoresGetTheOnlinePrice() async throws {
        let quotes = try await findQuotes(walmart: StubWalmart(.success(KrogerPrice(regular: 3.42, description: "GV Milk"))))
        let walmart = walmartQuotes(quotes)
        #expect(!walmart.isEmpty)
        #expect(walmart.allSatisfy { $0.availability == .online && $0.price == 3.42 && !$0.isSample })
        // Other chains stay samples.
        let target = quotes.filter { $0.store.chain == OtherChain.target.rawValue }
        #expect(!target.isEmpty && target.allSatisfy(\.isSample))
    }

    @Test func notFoundFallsBackToSampleAndErrorsShowAsFailed() async throws {
        let missing = walmartQuotes(try await findQuotes(walmart: StubWalmart(.success(nil))))
        #expect(!missing.isEmpty && missing.allSatisfy(\.isSample))
        let failed = walmartQuotes(try await findQuotes(walmart: StubWalmart(.failure(APIError.badStatus(500, "")))))
        #expect(!failed.isEmpty && failed.allSatisfy { $0.availability == .failed && $0.price == nil })
    }

    @Test func noKeyMeansSamplePrices() async throws {
        let walmart = walmartQuotes(try await findQuotes(walmart: MockWalmartService()))
        #expect(!walmart.isEmpty && walmart.allSatisfy(\.isSample))
    }
}
