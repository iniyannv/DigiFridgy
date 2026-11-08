import SwiftUI

struct InventoryView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank
    @State private var showConnectBank = false
    @State private var showCardPurchases = false
    @State private var showBarcodeScanner = false
    @State private var showReceiptScanner = false
    @State private var search = ""

    private var filtered: [FridgeItem] {
        let sorted = app.sortedItems
        guard !search.isEmpty else { return sorted }
        return sorted.filter { ($0.name + " " + ($0.brand ?? "")).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !app.itemsLoaded {
                    loadingSkeleton
                } else if app.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(app.household?.name ?? "Fridge")
            .navigationDestination(for: String.self) { ItemDetailView(itemId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ShoppingListView()
                    } label: {
                        Image(systemName: "checklist")
                            .overlay(alignment: .topTrailing) {
                                let open = app.shoppingList.filter { !$0.done }.count
                                if open > 0 {
                                    Text("\(open)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(3).background(.red, in: .circle).offset(x: 8, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("Shopping list")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Scan barcode", systemImage: "barcode.viewfinder") { showBarcodeScanner = true }
                        Button("Scan receipt", systemImage: "doc.text.viewfinder") { showReceiptScanner = true }
                        if bank.isLinked {
                            Button("Add from card", systemImage: "creditcard") { showCardPurchases = true }
                        } else if bank.status == .notLinked {
                            Button("Connect your bank", systemImage: "building.columns") { showConnectBank = true }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add items")
                }
            }
            .sheet(isPresented: $showBarcodeScanner) { BarcodeScanSheet() }
            .sheet(isPresented: $showReceiptScanner) { ReceiptScanSheet() }
            .sheet(isPresented: $showConnectBank) { ConnectBankSheet() }
            .sheet(isPresented: $showCardPurchases) { AddFromCardSheet() }
        }
    }

    private var list: some View {
        List {
            if search.isEmpty {
                Section {
                    FridgeSummaryCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if bank.isLinked || bank.status == .notLinked {
                    Section { BankBudgetCard() }
                }
            }

            if search.isEmpty && !app.approvals.isEmpty {
                ApprovalsSection()
            }

            let recalled = app.recalledItems
            if !recalled.isEmpty && search.isEmpty {
                Section {
                    ForEach(recalled) { item in
                        NavigationLink(value: item.id) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("Recall: \(item.name)").bold()
                                    Text(item.recallFlag?.reason ?? "").font(.caption).lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                        .listRowBackground(Color.red.opacity(0.12))
                    }
                }
            }

            let groups: [(String, [FridgeItem])] = [
                ("Expired", filtered.filter { $0.urgency() == .expired }),
                ("Use soon", filtered.filter { $0.urgency() == .soon }),
                ("Later", filtered.filter { $0.urgency() == .ok }),
            ]
            ForEach(groups, id: \.0) { title, items in
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: item.id) { InventoryRow(item: item) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await app.delete(item) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await app.adjustCount(item, by: -1) }
                                    } label: {
                                        Label(item.count > 1 ? "−1" : "Used up", systemImage: "minus.circle")
                                    }
                                    .tint(.orange)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        Task { await app.adjustCount(item, by: 1) }
                                    } label: {
                                        Label("+1", systemImage: "plus.circle")
                                    }
                                    .tint(.green)
                                }
                        }
                    } header: {
                        Text(title)
                    } footer: {
                        // Bank purchases know their price, so expired food has a dollar figure.
                        let lost = items.filter { $0.urgency() == .expired }.compactMap(\.value).reduce(0, +)
                        if lost > 0 {
                            Text("\(lost.formatted(.currency(code: "USD"))) of groceries expired. Toss or use them so your budget stays accurate.")
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search your fridge")
        .refreshable { await app.runChecks() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your fridge is empty", systemImage: "refrigerator")
        } description: {
            Text(bank.isLinked
                 ? "Scan a barcode or a receipt, or buy groceries with your card, to start tracking what you have and when it expires."
                 : "Scan a barcode or a grocery receipt to start tracking what you have and when it expires.")
        } actions: {
            Button("Scan barcode", systemImage: "barcode.viewfinder") { showBarcodeScanner = true }
                .buttonStyle(.glassProminent)
            Button("Scan receipt", systemImage: "doc.text.viewfinder") { showReceiptScanner = true }
                .buttonStyle(.glass)
            if bank.status == .notLinked {
                Button("Connect your bank", systemImage: "building.columns") { showConnectBank = true }
                    .buttonStyle(.glass)
            }
            if app.services.isMock {
                Button("Load demo items") { Task { await app.seedDemoHousehold() } }
                    .font(.footnote)
            }
        }
    }

    private var loadingSkeleton: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11).fill(.fill.tertiary).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(.fill.tertiary).frame(width: 160, height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(.fill.quaternary).frame(width: 100, height: 10)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}

struct InventoryRow: View {
    @Environment(AppState.self) private var app
    var item: FridgeItem

    var body: some View {
        HStack(spacing: 12) {
            ItemThumbnail(item: item)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(item.urgency().tint).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    if item.recallFlag != nil {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                            .accessibilityLabel("Recalled")
                    }
                    if !item.allergenHits(for: app.userAllergens).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityLabel("Contains your allergen")
                    }
                    if item.isCardPurchase {
                        Image(systemName: "creditcard.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Bought with your card")
                    }
                }
                ExpiryLabel(item: item)
            }
            Spacer()
            if item.count > 1 {
                Text("×\(item.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
