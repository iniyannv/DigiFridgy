import SwiftUI
import MapKit

/// Product being priced: a fridge item or a shopping-list entry.
struct PriceTarget: Hashable {
    var name: String
    var upc: String?
    var categoryID: String

    init(item: FridgeItem) {
        name = item.name
        upc = item.normalizedBarcode
        categoryID = item.category
    }

    init(name: String, upc: String?, shelfLife: ShelfLifeService = .shared) {
        self.name = name
        self.upc = upc
        categoryID = shelfLife.categoryID(forName: name)
    }
}

struct StoresTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            List {
                let open = app.shoppingList.filter { !$0.done }
                if !open.isEmpty {
                    Section("Shopping list") {
                        ForEach(open) { entry in
                            NavigationLink(value: PriceTarget(name: entry.name, upc: entry.barcode)) {
                                Label(entry.name, systemImage: "checklist")
                            }
                        }
                    }
                }
                Section {
                    if app.items.isEmpty {
                        Text("Scan items to compare their prices nearby.").foregroundStyle(.secondary)
                    }
                    ForEach(app.sortedItems) { item in
                        NavigationLink(value: PriceTarget(item: item)) {
                            HStack(spacing: 12) {
                                ItemThumbnail(item: item, size: 36)
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if let brand = item.brand { Text(brand).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if app.isWatched(item) {
                                    Image(systemName: "bell.badge.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("In your fridge")
                } footer: {
                    Text(app.services.kroger.isLive
                         ? "Kroger prices are live from the Kroger API. Other chains show real nearby locations with sample prices."
                         : "Kroger API key not configured — all prices are samples.")
                }
            }
            .navigationTitle("Compare prices")
            .navigationDestination(for: PriceTarget.self) { PriceComparisonView(target: $0) }
        }
    }
}

struct PriceComparisonView: View {
    @Environment(AppState.self) private var app
    let target: PriceTarget

    @State private var radius: Double = 10
    @State private var quotes: [PriceQuote] = []
    @State private var hasLivePrices = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var userCoordinate: Coordinate?
    @State private var selectedStoreID: String?
    @State private var didLoadRadius = false

    init(target: PriceTarget) {
        self.target = target
    }

    init(item: FridgeItem) {
        self.target = PriceTarget(item: item)
    }

    private var cheapestID: String? { quotes.first(where: \.hasPrice)?.id }

    var body: some View {
        List {
            Section {
                map
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
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
                if isLoading && quotes.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in
                        QuoteRow(quote: Self.placeholderQuote, isCheapest: false).redacted(reason: .placeholder)
                    }
                } else if let errorMessage, quotes.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if quotes.isEmpty {
                    Text("No stores within \(Int(radius)) miles. Try a larger radius.").foregroundStyle(.secondary)
                } else {
                    ForEach(quotes) { quote in
                        Button {
                            openInMaps(quote.store)
                        } label: {
                            QuoteRow(quote: quote, isCheapest: quote.id == cheapestID)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(quote.id == selectedStoreID ? Color.accentColor.opacity(0.12) : nil)
                    }
                }
            } header: {
                Text("Cheapest first")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if quotes.contains(where: { $0.store.isKroger && !$0.isSample }) {
                        Text("Kroger-family prices are live from the Kroger API. “Not carried” means that store doesn't stock this product.")
                    }
                    if quotes.contains(where: \.isSample) {
                        Text("“Sample price” rows use real store locations with generated prices — those chains don't offer a public price API.")
                    }
                    Text("Tap a store to open directions in Apple Maps.")
                }
            }

            if let upc = target.upc, let item = app.items.first(where: { $0.normalizedBarcode == upc }) {
                Section {
                    Toggle(isOn: Binding(get: { app.isWatched(item) }, set: { _ in app.toggleWatch(item) })) {
                        Label("Watch price", systemImage: "bell.badge")
                    }
                } footer: {
                    Text("Get a notification when this item gets cheaper at your nearest Kroger.")
                }
            }
        }
        .navigationTitle(target.name)
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

    private var map: some View {
        Map(position: $position, selection: $selectedStoreID) {
            if let userCoordinate {
                Annotation("You", coordinate: userCoordinate.clCoordinate) {
                    Image(systemName: "person.fill")
                        .padding(6)
                        .background(.blue, in: .circle)
                        .foregroundStyle(.white)
                }
            }
            ForEach(quotes) { quote in
                let cheapest = quote.id == cheapestID
                Marker(quote.effectivePrice?.usd ?? "N/A",
                       systemImage: cheapest ? "star.fill" : (quote.hasPrice ? "cart.fill" : "xmark"),
                       coordinate: quote.store.coordinate.clCoordinate)
                    .tint(cheapest ? .green : (quote.isSample || !quote.hasPrice ? .gray : .blue))
                    .tag(quote.id)
            }
        }
        .mapControls { MapCompass() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let coordinate = await app.currentCoordinate()
        userCoordinate = coordinate
        do {
            let result = try await PriceFinder(services: app.services).quotes(
                name: target.name, upc: target.upc, categoryID: target.categoryID,
                near: coordinate, radiusMiles: radius)
            quotes = result.quotes
            hasLivePrices = result.hasLivePrices
            errorMessage = nil
            position = .automatic
        } catch {
            errorMessage = error.localizedDescription
            app.showError(error)
        }
    }

    private func openInMaps(_ store: Store) {
        selectedStoreID = store.id
        let item = MKMapItem(location: store.coordinate.clLocation, address: nil)
        item.name = store.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private static let placeholderQuote = PriceQuote(
        store: Store(id: "p", chain: "Store", name: "Store name here", address: "Address", coordinate: .demoFallback,
                     distanceMiles: 1.2, isKroger: false),
        price: 3.49, availability: .live)
}

private struct QuoteRow: View {
    var quote: PriceQuote
    var isCheapest: Bool

    private var iconColor: Color {
        if isCheapest { return .green }
        return quote.availability == .live ? .blue : .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCheapest ? "star.circle.fill" : (quote.store.isKroger ? "k.circle.fill" : "cart.circle.fill"))
                .font(.title2)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(quote.store.chain).font(.body.weight(.semibold))
                    if quote.isSample { SampleBadge() }
                }
                Text(quote.store.name == quote.store.chain ? quote.store.address : quote.store.name)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if quote.availability == .live, let description = quote.productDescription {
                    Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(String(format: "%.1f mi", quote.store.distanceMiles))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                switch quote.availability {
                case .notCarried:
                    Text("Not carried")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Store doesn't have this item").font(.caption2).foregroundStyle(.tertiary)
                case .failed:
                    Text("Price unavailable")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Kroger didn't respond").font(.caption2).foregroundStyle(.tertiary)
                case .live, .sample:
                    if let effective = quote.effectivePrice {
                        Text(effective.usd)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(isCheapest ? .green : .primary)
                    }
                    if let promo = quote.promoPrice, let price = quote.price, promo < price {
                        Text(price.usd).font(.caption).strikethrough().foregroundStyle(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .contentShape(.rect)
    }
}
