import Foundation

/// Gathers prices for one product: live Kroger (when configured) + MapKit stores with sample prices.
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

        // Live Kroger prices, concurrently per store.
        var livePrices: [String: KrogerPrice] = [:]
        if kroger.isLive {
            livePrices = await withTaskGroup(of: (String, KrogerPrice?).self) { group in
                for store in krogerStores {
                    group.addTask { (store.id, try? await kroger.price(upc: upc, term: name, locationId: store.id)) }
                }
                var result: [String: KrogerPrice] = [:]
                for await (id, price) in group { if let price { result[id] = price } }
                return result
            }
        }

        // Reference = median live Kroger price, else the category baseline.
        let live = livePrices.values.map(\.regular).sorted()
        let reference = live.isEmpty ? mock.referencePrice(categoryID: categoryID) : live[live.count / 2]

        var quotes: [PriceQuote] = krogerStores.map { store in
            if let price = livePrices[store.id] {
                return PriceQuote(store: store, price: price.regular, promoPrice: price.promo, isSample: false,
                                  productDescription: price.description)
            }
            return PriceQuote(store: store, price: mock.price(upc: upc, name: name, chain: store.chain + store.id,
                                                              referencePrice: reference),
                              promoPrice: nil, isSample: true, productDescription: nil)
        }

        let others = await services.storeSearch.stores(near: near, radiusMiles: radiusMiles, chains: OtherChain.allCases)
        quotes += others.map { store in
            PriceQuote(store: store, price: mock.price(upc: upc, name: name, chain: store.chain, referencePrice: reference),
                       promoPrice: nil, isSample: true, productDescription: nil)
        }

        quotes.sort { ($0.effectivePrice, $0.store.distanceMiles) < ($1.effectivePrice, $1.store.distanceMiles) }
        return Result(quotes: quotes, hasLivePrices: !livePrices.isEmpty)
    }
}
