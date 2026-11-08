import Foundation

/// Gathers prices for one product: live Kroger (when configured; "not carried" when a store lacks it)
/// + MapKit stores of other chains with sample prices.
struct PriceFinder {
    let services: AppServices

    struct Result {
        var quotes: [PriceQuote]
        var hasLivePrices: Bool
    }

    func quotes(name: String, upc: String?, categoryID: String, near: Coordinate, radiusMiles: Double) async throws -> Result {
        let kroger = services.kroger
        let mock = services.mockPrices
        let krogerStores = try await kroger.locations(near: near, radiusMiles: radiusMiles, limit: 5)

        // Live Kroger prices, concurrently per store. No price = the store doesn't carry it.
        var liveResults: [String: Swift.Result<KrogerPrice?, any Error>] = [:]
        if kroger.isLive {
            liveResults = await withTaskGroup(of: (String, Swift.Result<KrogerPrice?, any Error>).self) { group in
                for store in krogerStores {
                    group.addTask {
                        do { return (store.id, .success(try await kroger.price(upc: upc, term: name, locationId: store.id))) }
                        catch { return (store.id, .failure(error)) }
                    }
                }
                var result: [String: Swift.Result<KrogerPrice?, any Error>] = [:]
                for await (id, outcome) in group { result[id] = outcome }
                return result
            }
        }
        let livePrices = liveResults.compactMapValues { try? $0.get() }

        // Reference for sample prices at other chains = median live Kroger price, else the category baseline.
        let live = livePrices.values.map(\.regular).sorted()
        let reference = live.isEmpty ? mock.referencePrice(categoryID: categoryID) : live[live.count / 2]

        var quotes: [PriceQuote] = krogerStores.map { store in
            guard kroger.isLive else {
                // No Kroger key (offline mode): everything is a sample.
                return PriceQuote(store: store, price: mock.price(upc: upc, name: name, chain: store.chain + store.id,
                                                                  referencePrice: reference),
                                  availability: .sample)
            }
            switch liveResults[store.id] {
            case .success(let price?):
                return PriceQuote(store: store, price: price.regular, promoPrice: price.promo, availability: .live,
                                  productDescription: price.description)
            case .success(nil):
                return PriceQuote(store: store, availability: .notCarried)
            case .failure, nil:
                return PriceQuote(store: store, availability: .failed)
            }
        }

        let others = await services.storeSearch.stores(near: near, radiusMiles: radiusMiles, chains: OtherChain.allCases)
        quotes += others.map { store in
            PriceQuote(store: store, price: mock.price(upc: upc, name: name, chain: store.chain, referencePrice: reference),
                       availability: .sample)
        }

        // Priced stores cheapest first, then stores without a price by distance.
        quotes.sort { a, b in
            switch (a.effectivePrice, b.effectivePrice) {
            case let (pa?, pb?): (pa, a.store.distanceMiles) < (pb, b.store.distanceMiles)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.store.distanceMiles < b.store.distanceMiles
            }
        }
        return Result(quotes: quotes, hasLivePrices: !livePrices.isEmpty)
    }
}
