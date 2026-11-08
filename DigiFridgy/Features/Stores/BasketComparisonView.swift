import SwiftUI
import MapKit

/// Sales tax added to basket totals.
nonisolated enum SalesTax {
    /// Dallas–Fort Worth combined rate: 6.25% Texas state plus 2% city and transit.
    static let dfwRate = 0.0825
    static let areaName = "DFW"

    /// "8.25%"
    static var rateText: String { dfwRate.formatted(.percent.precision(.fractionLength(0...2))) }

    static func tax(on subtotal: Double, rate: Double = dfwRate) -> Double {
        (subtotal * rate * 100).rounded() / 100
    }
}

/// One shopping-list entry's price at one store.
nonisolated struct BasketLine: Hashable, Sendable {
    var name: String
    /// Price for the whole line (unit price × quantity). Nil when the store doesn't carry it or the lookup failed.
    var price: Double?
    var availability: PriceQuote.Availability
    var quantity = 1

    /// The same line for `quantity` units.
    func times(_ quantity: Int) -> BasketLine {
        var line = self
        line.quantity = max(quantity, 1)
        line.price = price.map { ($0 * Double(line.quantity) * 100).rounded() / 100 }
        return line
    }
}

/// The whole shopping list priced at one store, with tax.
nonisolated struct StoreBasket: Identifiable, Hashable, Sendable {
    var store: Store
    var lines: [BasketLine]
    var taxRate: Double = SalesTax.dfwRate

    var id: String { store.id }
    var subtotal: Double { lines.compactMap(\.price).reduce(0, +) }
    var tax: Double { SalesTax.tax(on: subtotal, rate: taxRate) }
    var total: Double { subtotal + tax }
    var pricedCount: Int { lines.filter { $0.price != nil }.count }
    var missingCount: Int { lines.count - pricedCount }
    var isComplete: Bool { missingCount == 0 }
    /// Every price here is a generated sample.
    var isAllSample: Bool { lines.allSatisfy { $0.availability == .sample || $0.price == nil } }
    var hasSample: Bool { lines.contains { $0.availability == .sample } }

    /// Stores with the whole list first, cheapest first; then partial baskets by fewest missing.
    static func ranked(_ baskets: [StoreBasket]) -> [StoreBasket] {
        baskets.sorted { a, b in
            if a.missingCount != b.missingCount { return a.missingCount < b.missingCount }
            if a.total != b.total { return a.total < b.total }
            return a.store.distanceMiles < b.store.distanceMiles
        }
    }
}

/// Prices a whole shopping list at nearby stores: live Kroger prices per store, walmart.com prices, and
/// sample prices at other chains (same sources as single-item comparison, but stores are looked up once).
struct BasketPriceFinder {
    let services: AppServices
    /// Live Kroger lookups are one call per item per store, so only the nearest few stores.
    var krogerStoreLimit = 3

    /// `quantities[i]` is how many of `targets[i]` to buy (1 when missing).
    func baskets(for targets: [PriceTarget], quantities: [Int] = [], near: Coordinate,
                 radiusMiles: Double) async throws -> [StoreBasket] {
        let kroger = services.kroger
        let walmart = services.walmart
        let mock = services.mockPrices

        let krogerStores: [Store]
        var krogerError: (any Error)?
        do {
            krogerStores = try await kroger.locations(near: near, radiusMiles: radiusMiles, limit: krogerStoreLimit)
        } catch {
            krogerStores = []
            krogerError = error
        }
        // One store per other chain (the nearest): their prices are per chain, not per store.
        var nearestByChain: [String: Store] = [:]
        for store in await services.storeSearch.stores(near: near, radiusMiles: radiusMiles, chains: OtherChain.allCases) {
            if let current = nearestByChain[store.chain], current.distanceMiles <= store.distanceMiles { continue }
            nearestByChain[store.chain] = store
        }
        let others = nearestByChain.values.sorted { $0.distanceMiles < $1.distanceMiles }
        if krogerStores.isEmpty && others.isEmpty, let krogerError { throw krogerError }

        // Price items a few at a time so a long list doesn't fire every request at once.
        var linesByItem: [Int: [String: BasketLine]] = [:]
        let chunks = stride(from: 0, to: targets.count, by: 4).map { Array(targets.indices[$0..<min($0 + 4, targets.count)]) }
        for chunk in chunks {
            await withTaskGroup(of: (Int, [String: BasketLine]).self) { group in
                for index in chunk {
                    let target = targets[index]
                    group.addTask {
                        (index, await Self.lines(for: target, krogerStores: krogerStores, others: others,
                                                 kroger: kroger, walmart: walmart, mock: mock))
                    }
                }
                for await (index, lines) in group { linesByItem[index] = lines }
            }
        }

        let stores = krogerStores + others
        let baskets = stores.map { store in
            StoreBasket(store: store, lines: targets.indices.map { index in
                let line = linesByItem[index]?[store.id] ?? BasketLine(name: targets[index].name, price: nil, availability: .failed)
                return line.times(index < quantities.count ? quantities[index] : 1)
            })
        }
        return StoreBasket.ranked(baskets)
    }

    /// One item's price at every store, keyed by store id.
    private static func lines(for target: PriceTarget, krogerStores: [Store], others: [Store],
                              kroger: any KrogerService, walmart: any WalmartService,
                              mock: MockPriceService) async -> [String: BasketLine] {
        async let walmartPrice: KrogerPrice? = walmart.isLive
            ? (try? await walmart.price(upc: target.upc, term: target.name)) : nil

        var live: [String: Swift.Result<KrogerPrice?, any Error>] = [:]
        if kroger.isLive {
            for store in krogerStores {
                do { live[store.id] = .success(try await kroger.price(upc: target.upc, term: target.name, locationId: store.id)) }
                catch { live[store.id] = .failure(error) }
            }
        }
        let online = await walmartPrice

        let livePrices = live.values.compactMap { try? $0.get() }.map(\.effective).sorted()
        let reference = livePrices.isEmpty
            ? (online?.regular ?? mock.referencePrice(categoryID: target.categoryID))
            : livePrices[livePrices.count / 2]

        var lines: [String: BasketLine] = [:]
        for store in krogerStores {
            guard kroger.isLive else {
                lines[store.id] = BasketLine(name: target.name,
                                             price: mock.price(upc: target.upc, name: target.name,
                                                               chain: store.chain + store.id, referencePrice: reference),
                                             availability: .sample)
                continue
            }
            switch live[store.id] {
            case .success(let price?): lines[store.id] = BasketLine(name: target.name, price: price.effective, availability: .live)
            case .success(nil): lines[store.id] = BasketLine(name: target.name, price: nil, availability: .notCarried)
            case .failure, nil: lines[store.id] = BasketLine(name: target.name, price: nil, availability: .failed)
            }
        }
        for store in others {
            if store.chain == OtherChain.walmart.rawValue, let online {
                lines[store.id] = BasketLine(name: target.name, price: online.effective, availability: .online)
            } else {
                lines[store.id] = BasketLine(name: target.name,
                                             price: mock.price(upc: target.upc, name: target.name, chain: store.chain,
                                                               referencePrice: reference),
                                             availability: .sample)
            }
        }
        return lines
    }
}

/// The whole shopping list priced at each nearby store, with DFW sales tax, cheapest complete basket first.
struct BasketComparisonView: View {
    @Environment(AppState.self) private var app
    var entries: [ShoppingListItem]

    @State private var baskets: [StoreBasket] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var radius: Double = 10
    @State private var didLoadRadius = false
    @State private var expanded: Set<String> = []

    private var targets: [PriceTarget] { entries.map { PriceTarget(name: $0.name, upc: $0.barcode) } }
    private var best: StoreBasket? { baskets.first { $0.isComplete } ?? baskets.first }
    private var priciest: StoreBasket? { baskets.filter(\.isComplete).max { $0.total < $1.total } }

    var body: some View {
        List {
            if let best, !isLoading || !baskets.isEmpty {
                Section { summary(best) }
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Search radius")
                        Spacer()
                        Text("\(Int(radius)) mi").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $radius, in: 1...50, step: 1) { editing in
                        if !editing {
                            app.setSearchRadius(radius)
                            Task { await load() }
                        }
                    }
                }
            }

            Section {
                if isLoading && baskets.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        BasketRow(basket: Self.placeholder, isBest: false, isExpanded: false).redacted(reason: .placeholder)
                    }
                } else if let errorMessage, baskets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load prices", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                        Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                } else if baskets.isEmpty {
                    Text("No stores within \(Int(radius)) miles. Widen the search radius.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(baskets) { basket in
                        let isExpanded = expanded.contains(basket.id)
                        Button {
                            withAnimation(.snappy) {
                                if isExpanded { expanded.remove(basket.id) } else { expanded.insert(basket.id) }
                            }
                        } label: {
                            BasketRow(basket: basket, isBest: basket.id == best?.id, isExpanded: isExpanded)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(isExpanded ? "Hides item prices" : "Shows each item's price")
                        .contextMenu {
                            Button("Directions", systemImage: "car") { openInMaps(basket.store) }
                        }
                        if isExpanded {
                            BasketBreakdown(basket: basket) { openInMaps(basket.store) }
                        }
                    }
                }
            } header: {
                let units = entries.map(\.count).reduce(0, +)
                Text("\(units) \(units == 1 ? "item" : "items") · total with tax")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Totals include \(SalesTax.rateText) \(SalesTax.areaName) sales tax on every item. Texas exempts most unprepared food, so your receipt may come out lower.")
                    if baskets.contains(where: \.hasSample) {
                        Text("“Sample” totals use real nearby stores with generated prices; those chains don't offer a public price API.")
                    }
                    if baskets.contains(where: { $0.store.isKroger && !$0.isAllSample }) {
                        Text("Kroger prices are live for each store. Walmart uses walmart.com prices.")
                    }
                    Text("Tap a store to see each item's price.")
                }
            }
        }
        .navigationTitle("Compare stores")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if !didLoadRadius {
                radius = app.profile?.searchRadiusMiles ?? 10
                didLoadRadius = true
            }
            await load()
        }
    }

    private func summary(_ best: StoreBasket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(best.isComplete ? "Cheapest for your whole list" : "Most of your list")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(best.store.chain).font(.title2.bold())
                if best.isAllSample { SampleBadge() }
                Spacer()
                Text(best.total.usd).font(.title2.bold().monospacedDigit()).foregroundStyle(Tone.success.color)
            }
            Text("\(best.subtotal.usd) + \(best.tax.usd) tax · \(best.store.distanceMiles, format: .number.precision(.fractionLength(1))) mi away")
                .font(.caption).foregroundStyle(.secondary)
            if let priciest, priciest.id != best.id, best.isComplete, priciest.total - best.total >= 0.01 {
                Label("Saves \((priciest.total - best.total).usd) vs. \(priciest.store.chain)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tone.success.color)
            }
            if !best.isComplete {
                Text("No store nearby has every item. This one is missing \(best.missingCount).")
                    .font(.caption).foregroundStyle(Tone.warning.color)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard !targets.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let coordinate = await app.currentCoordinate()
        do {
            baskets = try await BasketPriceFinder(services: app.services)
                .baskets(for: targets, quantities: entries.map(\.count), near: coordinate, radiusMiles: radius)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if !baskets.isEmpty { app.showError(error) }
        }
    }

    private func openInMaps(_ store: Store) {
        let item = MKMapItem(location: store.coordinate.clLocation, address: nil)
        item.name = store.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private static let placeholder = StoreBasket(
        store: Store(id: "p", chain: "Store", name: "Store name", address: "Address", coordinate: .demoFallback,
                     distanceMiles: 1.2, isKroger: false),
        lines: [BasketLine(name: "Item", price: 12.49, availability: .live)])
}

private struct BasketRow: View {
    var basket: StoreBasket
    var isBest: Bool
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isBest ? "star.circle.fill" : (basket.store.isKroger ? "k.circle.fill" : "cart.circle.fill"))
                .font(.title2)
                .foregroundStyle(isBest ? Tone.success.color : basket.isAllSample ? .secondary : Tone.info.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(basket.store.chain).font(.body.weight(.semibold))
                    if basket.isAllSample { StatusChip(text: "Sample", tone: .warning) }
                }
                Text(basket.store.name == basket.store.chain ? basket.store.address : basket.store.name)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(basket.store.distanceMiles, format: .number.precision(.fractionLength(1))) mi")
                    Text("·")
                    Text(basket.isComplete ? "All \(basket.lines.count) items" : "\(basket.pricedCount) of \(basket.lines.count) items")
                        .foregroundStyle(basket.isComplete ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Tone.warning.color))
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(basket.total.usd)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(isBest ? Tone.success.color : .primary)
                Text("incl. \(basket.tax.usd) tax").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct BasketBreakdown: View {
    var basket: StoreBasket
    var directions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(basket.lines.enumerated()), id: \.offset) { _, line in
                HStack {
                    Text(line.quantity > 1 ? "\(line.quantity) × \(line.name)" : line.name).lineLimit(1)
                    if line.availability == .sample { StatusChip(text: "Sample", tone: .warning) }
                    if line.availability == .online { StatusChip(text: "Walmart.com", tone: .info) }
                    Spacer()
                    if let price = line.price {
                        Text(price.usd).monospacedDigit()
                    } else {
                        Text(line.availability == .notCarried ? "Not carried" : "Unavailable").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Divider()
            row("Subtotal", basket.subtotal.usd)
            row("Sales tax (\(SalesTax.rateText))", basket.tax.usd)
            row("Total", basket.total.usd).bold()
            Button("Directions", systemImage: "car", action: directions)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .padding(.leading, 40)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}
