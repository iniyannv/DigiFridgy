import Testing
import Foundation
@testable import DigiFridgy

struct TrajectParsingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func blueCartSearchMapsToProducts() throws {
        let json = """
        {"request_info":{"success":true,"credits_used":1,"credits_remaining":99},
         "search_results":[
          {"position":1,
           "product":{"title":"Great Value Whole Milk, 1 Gallon","link":"https://www.walmart.com/ip/10450114",
                      "item_id":"10450114","product_id":"3S5ZM1","rating":4.6,"ratings_total":5120,
                      "images":{"primary_image":"https://i5.walmartimages.com/milk.jpeg"}},
           "inventory":{"in_stock":true,"stock_level":40},
           "offers":{"primary":{"price":3.42,"currency":"USD"}}},
          {"position":2,"product":{"title":"No price or image","item_id":12345}},
          {"position":3,"product":{"link":"https://www.walmart.com/ip/1"}},
          {"position":4,"product":{"title":"Odd shape","rating":"not a number"}}
         ]}
        """
        let products = try decode(LiveTrajectSearchService.BlueCartResponse.self, json).products
        #expect(products.count == 2)

        let milk = try #require(products.first)
        #expect(milk.id == "walmart-10450114")
        #expect(milk.retailer == .walmart)
        #expect(milk.price == 3.42)
        #expect(milk.imageURL?.absoluteString == "https://i5.walmartimages.com/milk.jpeg")
        #expect(milk.productURL?.absoluteString == "https://www.walmart.com/ip/10450114")
        #expect(milk.rating == 4.6 && milk.ratingsTotal == 5120 && milk.inStock == true)

        // Numeric item_id still makes an ID; missing price and image stay nil.
        #expect(products[1].id == "walmart-12345")
        #expect(products[1].price == nil && products[1].imageURL == nil)
    }

    @Test func redCircleSearchMapsToProducts() throws {
        let json = """
        {"search_results":[
          {"position":1,
           "product":{"title":"Whole Milk - 1gal - Good & Gather","link":"https://www.target.com/p/-/A-13276134",
                      "tcin":"13276134","brand":"Good & Gather","rating":4.5,"ratings_total":980,
                      "main_image":"https://target.scene7.com/is/image/Target/GUEST_milk"},
           "offers":{"primary":{"price":3.89,"currency":"USD","symbol":"$"}},
           "fulfillment":{"type":"1p"}}
        ]}
        """
        let products = try decode(LiveTrajectSearchService.RedCircleResponse.self, json).products
        let milk = try #require(products.first)
        #expect(products.count == 1)
        #expect(milk.id == "target-13276134")
        #expect(milk.retailer == .target)
        #expect(milk.price == 3.89)
        #expect(milk.imageURL?.absoluteString == "https://target.scene7.com/is/image/Target/GUEST_milk")
        #expect(milk.inStock == nil)
    }

    @Test func missingSearchResultsIsEmpty() throws {
        #expect(try decode(LiveTrajectSearchService.BlueCartResponse.self, "{}").products.isEmpty)
        #expect(try decode(LiveTrajectSearchService.RedCircleResponse.self, #"{"search_results":[]}"#).products.isEmpty)
    }

    @Test func outOfCreditsHasAFriendlyMessage() {
        let error = TrajectError(status: 402, body: "", provider: "BlueCart (Walmart)")
        #expect(error.errorDescription == "BlueCart (Walmart) is out of search credits.")
    }
}

@MainActor
private final class StubSearch: ProductSearchService {
    let retailer: OtherChain
    let result: Result<[RetailProduct], any Error>
    private(set) var calls = 0
    init(_ retailer: OtherChain, _ result: Result<[RetailProduct], any Error>) {
        self.retailer = retailer
        self.result = result
    }
    let isLive = true
    func search(_ term: String) async throws -> [RetailProduct] {
        calls += 1
        return try result.get()
    }
}

@MainActor
struct ProductSearchFlowTests {
    @Test func oneRetailerFailingKeepsTheOthersResults() async throws {
        let product = RetailProduct(id: "target-1", retailer: .target, title: "Milk", price: 3.89)
        let walmart = StubSearch(.walmart, .failure(TrajectError(status: 402, body: "", provider: "BlueCart")))
        let target = StubSearch(.target, .success([product]))
        let result = await ProductSearch.load(term: "milk", walmart: walmart, target: target)
        #expect(throws: TrajectError.self) { try result.walmart.get() }
        #expect(try result.target.get() == [product])
        #expect(walmart.calls == 1 && target.calls == 1)
    }

    @Test func mockSearchGivesStableSampleResults() async throws {
        let mock = MockProductSearchService(retailer: .target)
        let first = try await mock.search(" whole milk ")
        let second = try await mock.search("whole milk")
        #expect(first.count == 3 && first == second)
        #expect(first.allSatisfy { $0.retailer == .target && ($0.price ?? 0) > 0 && $0.title.hasSuffix("Whole Milk") })
        #expect(try await mock.search("   ").isEmpty)
    }

    @Test func testsUseSampleSearchAndLiveClientNeedsAKey() async throws {
        let services = AppServices.mock()
        #expect(!services.walmartSearch.isLive && !services.targetSearch.isLive)
        // The test bundle has no Traject keys, so the live client refuses instead of calling out.
        let live = LiveTrajectSearchService(.blueCart)
        #expect(!live.isLive)
        await #expect(throws: APIError.self) { try await live.search("milk") }
        #expect(try await live.search("  ").isEmpty)
    }
}
