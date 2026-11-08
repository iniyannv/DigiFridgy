import Testing
import Foundation
@testable import DigiFridgy

@MainActor
struct ProductOverrideTests {
    @Test func savedCorrectionsApplyOnRescan() async throws {
        let app = AppState(services: .mock())
        let code = "0078742351865"   // Demo "Whole Milk"
        var corrected = try #require(try await app.draftForScan(barcode: code))
        #expect(corrected.name == "Whole Milk")

        corrected.name = "Organic Whole Milk"
        corrected.category = "plant_milk"
        corrected.nutrition?.kcal = 160
        app.services.productOverrides.remember(corrected)

        let rescanned = try #require(try await app.draftForScan(barcode: code))
        #expect(rescanned.name == "Organic Whole Milk")
        #expect(rescanned.category == "plant_milk")
        #expect(rescanned.nutrition?.kcal == 160)
        #expect(app.hasSavedCorrections(barcode: code))
    }

    @Test func savedCorrectionsCoverUnknownBarcodes() async throws {
        let app = AppState(services: .mock())
        let code = "0000000000017"
        #expect(try await app.draftForScan(barcode: code) == nil)

        let typed = FridgeItem(barcode: code, name: "Farm stand eggs", category: "eggs", expiresAt: .now, source: .barcode)
        app.services.productOverrides.remember(typed)

        let rescanned = try #require(try await app.draftForScan(barcode: code))
        #expect(rescanned.name == "Farm stand eggs")
        #expect(rescanned.category == "eggs")
        #expect(rescanned.expiresAt > .now)
    }

    @Test func storePersistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overrides-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let item = FridgeItem(barcode: "078742351865", name: "Milk (fixed)", category: "milk", expiresAt: .now,
                              source: .barcode, nutrition: Nutrition(kcal: 90))
        ProductOverrideStore(fileURL: url).remember(item)

        let reloaded = ProductOverrideStore(fileURL: url).override(forBarcode: "0078742351865")
        #expect(reloaded?.name == "Milk (fixed)")
        #expect(reloaded?.nutrition?.kcal == 90)
    }
}

struct KrogerSearchTermTests {
    @Test func dropsSizesAndShortens() {
        #expect(LiveKrogerService.searchTerms(for: "Coca-Cola Classic Soda 20 fl oz bottle")
                == ["Coca-Cola Classic Soda", "Coca-Cola Classic"])
        #expect(LiveKrogerService.searchTerms(for: "Organic Baby Spinach 5oz")
                == ["Organic Baby Spinach", "Organic Baby"])
        #expect(LiveKrogerService.searchTerms(for: "Eggs") == ["Eggs"])
    }
}

struct EdamamHeaderTests {
    @Test func onlyRetriesWithUserHeaderWhenRequired() {
        let unsupported = #"{"error":"unauthorized","message":"This app does not support users. Do not supply the Edamam-Account-User header with it"}"#
        #expect(!EdamamRecipeService.requiresUserHeader(unsupported))
        let required = #"{"error":"unauthorized","message":"Edamam-Account-User header is required"}"#
        #expect(EdamamRecipeService.requiresUserHeader(required))
        #expect(!EdamamRecipeService.requiresUserHeader("Invalid app_id"))
    }
}

/// Kroger stub: one store has the item, one doesn't carry it, one errors.
private final class StubKroger: KrogerService {
    let isLive = true
    func locations(near: Coordinate, radiusMiles: Double, limit: Int) async throws -> [Store] {
        ["a", "b", "c"].enumerated().map { index, id in
            Store(id: "kroger-\(id)", chain: "Kroger", name: "Kroger \(id)", address: "", coordinate: near,
                  distanceMiles: Double(index), isKroger: true)
        }
    }
    func price(upc: String?, term: String, locationId: String) async throws -> KrogerPrice? {
        switch locationId {
        case "kroger-a": return KrogerPrice(regular: 3.19, promo: 2.99, description: "Kroger Milk")
        case "kroger-b": return nil
        default: throw APIError.badStatus(500, "")
        }
    }
}

@MainActor
struct PriceFinderTests {
    @Test func krogerStoresNeverGetSamplePrices() async throws {
        let mock = AppServices.mock()
        let services = AppServices(
            isMock: true, auth: mock.auth, repository: mock.repository, products: mock.products,
            recipes: mock.recipes, recalls: mock.recalls, kroger: StubKroger(), storeSearch: mock.storeSearch,
            location: mock.location, ocr: mock.ocr, normalizer: mock.normalizer, notifications: mock.notifications)
        let result = try await PriceFinder(services: services).quotes(
            name: "Whole Milk", upc: "0078742351865", categoryID: "milk", near: .demoFallback, radiusMiles: 10)

        let kroger = Dictionary(uniqueKeysWithValues: result.quotes.filter(\.store.isKroger).map { ($0.store.id, $0) })
        #expect(kroger["kroger-a"]?.availability == .live)
        #expect(kroger["kroger-a"]?.effectivePrice == 2.99)
        #expect(kroger["kroger-b"]?.availability == .notCarried)
        #expect(kroger["kroger-b"]?.price == nil)
        #expect(kroger["kroger-c"]?.availability == .failed)
        #expect(result.quotes.filter(\.store.isKroger).allSatisfy { !$0.isSample })
        // Stores without a price sort after every priced store.
        let firstUnpriced = try #require(result.quotes.firstIndex { !$0.hasPrice })
        #expect(result.quotes[firstUnpriced...].allSatisfy { !$0.hasPrice })
    }
}
