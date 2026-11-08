import SwiftUI

struct InventoryView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank
    @State private var showConnectBank = false
    @State private var showCardPurchases = false
    @State private var showBarcodeScanner = false
    @State private var showReceiptScanner = false
    @State private var search = ""
    @State private var countChanges = 0
    @State private var isSelecting = false
    @State private var selection: Set<String> = []

    private var filtered: [FridgeItem] {
        let sorted = app.sortedItems
        guard !search.isEmpty else { return sorted }
        return sorted.filter { ($0.name + " " + ($0.brand ?? "")).localizedCaseInsensitiveContains(search) }
    }

    private var openShopping: Int { app.shoppingList.filter { !$0.done }.count }

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
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let allIDs = Set(filtered.map(\.id))
                        Button(selection == allIDs && !allIDs.isEmpty ? "Deselect All" : "Select All") {
                            selection = selection == allIDs ? [] : allIDs
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { endSelecting() }.bold()
                    }
                } else {
                    normalToolbar
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    SelectionActionBar(count: selection.count) {
                        Button("Add to list", systemImage: "cart.badge.plus") {
                            app.addToShoppingList(names: selectedItems.map(\.name))
                            endSelecting()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let chosen = selectedItems
                            endSelecting()
                            Task { await app.delete(chosen) }
                        }
                        .tint(.red)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: isSelecting)
            .onChange(of: app.items.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .sheet(isPresented: $showBarcodeScanner) { BarcodeScanSheet() }
            .sheet(isPresented: $showReceiptScanner) { ReceiptScanSheet() }
            .sheet(isPresented: $showConnectBank) { ConnectBankSheet() }
            .sheet(isPresented: $showCardPurchases) { AddFromCardSheet() }
        }
    }

    private var selectedItems: [FridgeItem] { app.sortedItems.filter { selection.contains($0.id) } }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    @ToolbarContentBuilder
    private var normalToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                ShoppingListView()
            } label: {
                Label("Shopping list", systemImage: "checklist")
                    .overlay(alignment: .topTrailing) {
                        if openShopping > 0 {
                            Text("\(openShopping)").font(.caption2.bold()).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                .background(.red, in: .capsule)
                                .offset(x: 9, y: -8)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .accessibilityValue(openShopping > 0 ? "\(openShopping) to buy" : "")
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
                Label("Add items", systemImage: "plus")
            }
        }
        if !app.items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    private var list: some View {
        // Selection is bound only while selecting, so a normal tap opens the item instead of selecting it.
        List(selection: isSelecting ? $selection : nil) {
            if search.isEmpty && !isSelecting {
                Section {
                    FridgeSummaryCard()
                }
                if bank.isLinked || bank.status == .notLinked {
                    Section { BankBudgetCard() }
                }
            }

            if search.isEmpty && !isSelecting && !app.approvals.isEmpty {
                ApprovalsSection()
            }

            let recalled = app.recalledItems
            if !recalled.isEmpty && search.isEmpty && !isSelecting {
                Section {
                    ForEach(recalled) { item in
                        HStack(spacing: 4) {
                            NavigationLink(value: item.id) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text("\(item.recallFlag?.isPossible == true ? "Possible recall" : "Recall"): \(item.name)").bold()
                                        Text(item.recallFlag?.reason ?? "").font(.caption).lineLimit(2)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.octagon.fill")
                                        .foregroundStyle(item.recallFlag?.tone.color ?? Tone.danger.color)
                                }
                            }
                            Button {
                                Task { await app.dismissRecall(item) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss recall for \(item.name)")
                        }
                        .listRowBackground((item.recallFlag?.tone ?? .danger).fill)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { await app.dismissRecall(item) }
                            } label: {
                                Label("Dismiss", systemImage: "xmark")
                            }
                            .tint(.gray)
                        }
                        .contextMenu {
                            Button("Not my product", systemImage: "hand.raised") {
                                Task { await app.dismissRecall(item) }
                            }
                        }
                    }
                } footer: {
                    if recalled.contains(where: { $0.recallFlag?.isPossible == true }) {
                        Text("Possible recalls are close matches, not certain. Check the details, then dismiss any that aren't your product.")
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
                            if isSelecting {
                                InventoryRow(item: item).tag(item.id)
                            } else {
                                inventoryRow(item)
                            }
                        }
                    } header: {
                        Text(title)
                    } footer: {
                        // Bank purchases know their price, so expired food has a dollar figure.
                        let lost = items.filter { $0.urgency() == .expired }.compactMap(\.value).reduce(0, +)
                        if lost > 0 && !isSelecting {
                            Text("\(lost.usd) of groceries expired. Toss or use them so your budget stays accurate.")
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .overlay {
            if !search.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .sensoryFeedback(.selection, trigger: countChanges)
        .searchable(text: $search, prompt: "Search your fridge")
        .refreshable { await app.runChecks() }
        .expandsTabBarOnScrollUp()
    }

    private func inventoryRow(_ item: FridgeItem) -> some View {
                            NavigationLink(value: item.id) { InventoryRow(item: item) }
                                .tag(item.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await app.delete(item, undoable: true) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        countChanges += 1
                                        Task { await app.adjustCount(item, by: -1) }
                                    } label: {
                                        Label(item.count > 1 ? "Use one" : "Used up", systemImage: "minus.circle")
                                    }
                                    .tint(.orange)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        countChanges += 1
                                        Task { await app.adjustCount(item, by: 1) }
                                    } label: {
                                        Label("Add one", systemImage: "plus.circle")
                                    }
                                    .tint(.green)
                                }
                                .contextMenu {
                                    Button("Add one", systemImage: "plus.circle") {
                                        countChanges += 1
                                        Task { await app.adjustCount(item, by: 1) }
                                    }
                                    Button(item.count > 1 ? "Use one" : "Used up", systemImage: "minus.circle") {
                                        countChanges += 1
                                        Task { await app.adjustCount(item, by: -1) }
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await app.delete(item, undoable: true) }
                                    }
                                    Button("Select", systemImage: "checkmark.circle") {
                                        isSelecting = true
                                        selection = [item.id]
                                    }
                                }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your fridge is empty", systemImage: "refrigerator")
        } description: {
            Text("Scan what you buy and DigiFridgy tracks when it expires, so you use it before it goes bad.")
        } actions: {
            Button("Scan a barcode", systemImage: "barcode.viewfinder") { showBarcodeScanner = true }
                .buttonStyle(.glassProminent)
            Button("Scan a receipt", systemImage: "doc.text.viewfinder") { showReceiptScanner = true }
                .buttonStyle(.glass)
            if bank.isLinked {
                Button("Add from your card") { showCardPurchases = true }
                    .font(.footnote)
            } else if bank.status == .notLinked {
                Button("Or connect a card instead") { showConnectBank = true }
                    .font(.footnote)
            }
            if app.services.isMock {
                Button("Load demo items") { Task { await app.seedDemoHousehold() } }
                    .font(.footnote)
                Button("Load real-barcode demo") { Task { await app.seedBarcodeDemo() } }
                    .font(.footnote)
            }
        }
    }

    private var loadingSkeleton: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: Radius.medium).fill(.fill.tertiary).frame(width: 44, height: 44)
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
                        .accessibilityHidden(true) // ExpiryLabel says the same thing in words.
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    if let flag = item.recallFlag {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(flag.tone.color)
                            .accessibilityLabel(flag.isPossible ? "Possible recall" : "Recalled")
                    }
                    if !item.allergenHits(for: app.userAllergens).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color)
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
                    .accessibilityLabel("Quantity \(item.count)")
            }
        }
        .padding(.vertical, 2)
    }
}
