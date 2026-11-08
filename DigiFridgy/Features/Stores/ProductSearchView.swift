import SwiftUI

/// Navigation value for a submitted Stores-tab search.
struct ProductQuery: Hashable, Identifiable {
    var term: String
    var id: String { term }
}

extension View {
    /// Search field that opens walmart.com / target.com results when submitted.
    /// Apply inside a NavigationStack. Searches only on submit (each search costs API credits).
    func productSearch() -> some View {
        modifier(ProductSearchModifier())
    }
}

private struct ProductSearchModifier: ViewModifier {
    @State private var query = ""
    @State private var isSearching = false
    @State private var submitted: ProductQuery?

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $submitted) { ProductSearchView(term: $0.term) }
            .searchable(text: $query, isPresented: $isSearching,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Walmart & Target")
            .onSubmit(of: .search) {
                let term = ProductSearch.cleaned(query)
                guard !term.isEmpty else { return }
                // A push doesn't happen while the search field is still presented, so close it first.
                isSearching = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    submitted = ProductQuery(term: term)
                }
            }
    }
}

struct ProductSearchView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    var term: String

    @State private var walmart: ProductSearch.Outcome?
    @State private var target: ProductSearch.Outcome?

    var body: some View {
        List {
            section(service: app.services.walmartSearch, outcome: walmart) { await retry(.walmart) }
            section(service: app.services.targetSearch, outcome: target) { await retry(.target) }
        }
        .navigationTitle(term)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: term) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func section(service: any ProductSearchService, outcome: ProductSearch.Outcome?,
                         retry: @escaping () async -> Void) -> some View {
        Section {
            switch outcome {
            case nil:
                ForEach(0..<3, id: \.self) { _ in ProductRow(product: Self.placeholder, isSample: false) }
                    .redacted(reason: .placeholder)
            case .failure(let error)?:
                VStack(alignment: .leading, spacing: 6) {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await retry() } }
                }
                .padding(.vertical, 4)
            case .success(let products)? where products.isEmpty:
                Text("No results at \(service.retailer.rawValue).").foregroundStyle(.secondary)
            case .success(let products)?:
                ForEach(products) { product in
                    Button {
                        if let url = product.productURL { openURL(url) }
                    } label: {
                        ProductRow(product: product, isSample: !service.isLive)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(service.retailer.rawValue)
        } footer: {
            if service.retailer == .target {
                Text("Online prices from walmart.com and target.com via Traject Data, which isn't affiliated with either store. In-store prices may differ.")
            }
        }
    }

    private func load() async {
        walmart = nil
        target = nil
        let result = await ProductSearch.load(term: term, walmart: app.services.walmartSearch,
                                              target: app.services.targetSearch)
        walmart = result.walmart
        target = result.target
    }

    private func retry(_ retailer: OtherChain) async {
        let service = retailer == .target ? app.services.targetSearch : app.services.walmartSearch
        let set: (ProductSearch.Outcome?) -> Void = { retailer == .target ? (target = $0) : (walmart = $0) }
        set(nil)
        do { set(.success(try await service.search(term))) } catch { set(.failure(error)) }
    }

    private static let placeholder = RetailProduct(id: "placeholder", retailer: .walmart,
                                                   title: "Product name goes here, two lines", price: 3.49,
                                                   rating: 4.5, ratingsTotal: 100)
}

private struct ProductRow: View {
    var product: RetailProduct
    var isSample: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: product.imageURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "cart").foregroundStyle(.tertiary)
            }
            .frame(width: 52, height: 52)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(product.title).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let rating = product.rating {
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                        if let total = product.ratingsTotal { Text("(\(total))") }
                    }
                    if product.inStock == false { Text("Out of stock") }
                    if isSample { SampleBadge() }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let price = product.price {
                Text(price.usd).font(.body.weight(.bold).monospacedDigit())
            } else {
                Text("No price").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}
