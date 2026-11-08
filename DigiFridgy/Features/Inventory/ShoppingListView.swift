import SwiftUI

/// Price estimate for one shopping-list entry: what the household last paid on the card, or else the
/// category's *typical* price (a generated baseline, always labeled as such).
nonisolated struct ShoppingEstimate: Hashable, Sendable {
    var price: Double
    var paid: Bool

    /// "$3.49" for a price paid on the card, "~$3.49" for a typical one.
    var priceText: String { (paid ? "" : "~") + price.formatted(.currency(code: "USD")) }
    /// Badge shown next to typical prices.
    var badge: String? { paid ? nil : "Typical price" }

    static func estimate(name: String, items: [FridgeItem], typicalPrice: (String) -> Double) -> ShoppingEstimate {
        let wanted = Set(ShelfLifeService.tokenize(name))
        let paid = items
            .filter { item in
                guard item.price != nil, !wanted.isEmpty else { return false }
                // Whole words: "corn" doesn't match "popcorn", but "milk" matches "Whole Milk".
                let words = Set(ShelfLifeService.tokenize(item.name))
                return wanted.isSubset(of: words) || (!words.isEmpty && words.isSubset(of: wanted))
            }
            .max { $0.addedAt < $1.addedAt }?.price
        if let paid { return ShoppingEstimate(price: paid, paid: true) }
        return ShoppingEstimate(price: typicalPrice(name), paid: false)
    }

    /// "About $12.40", plus "(includes typical prices)" when any entry isn't a card price.
    static func totalText(_ estimates: [ShoppingEstimate]) -> String {
        let total = estimates.map(\.price).reduce(0, +).formatted(.currency(code: "USD"))
        return estimates.contains(where: { !$0.paid }) ? "About \(total) (includes typical prices)" : "About \(total)"
    }
}

struct ShoppingListView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank
    @State private var newItem = ""
    @State private var toggles = 0
    @State private var search = ""
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @FocusState private var addFocused: Bool

    private func estimate(_ entry: ShoppingListItem) -> ShoppingEstimate {
        ShoppingEstimate.estimate(name: entry.name, items: app.items) { name in
            app.services.mockPrices.referencePrice(categoryID: app.services.shelfLife.categoryID(forName: name))
        }
    }

    private var open: [ShoppingListItem] { app.shoppingList.filter { !$0.done } }

    private var filtered: [ShoppingListItem] {
        guard !search.isEmpty else { return app.shoppingList }
        return app.shoppingList.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var selectedEntries: [ShoppingListItem] { app.shoppingList.filter { selection.contains($0.id) } }

    var body: some View {
        List(selection: $selection) {
            if search.isEmpty && !isSelecting {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 11))
                            .accessibilityHidden(true)
                        TextField("Add an item", text: $newItem)
                            .focused($addFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !open.isEmpty { budgetSection }
            }

            let groups: [(String, [ShoppingListItem])] = [
                ("To buy", filtered.filter { !$0.done }),
                ("Bought", filtered.filter(\.done)),
            ]
            ForEach(groups, id: \.0) { title, entries in
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            if isSelecting {
                                ShoppingRow(entry: entry, estimate: estimate(entry), showsCheckbox: false)
                                    .tag(entry.id)
                            } else {
                                row(entry)
                            }
                        }
                    } header: {
                        Text(title)
                    } footer: {
                        if title == "To buy" && !isSelecting {
                            Text("Shared with everyone in \(app.household?.name ?? "your household"), and with the household's iMessage chat. Swipe right or touch and hold to say you'll get something.")
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .overlay {
            if app.shoppingList.isEmpty {
                EmptyStateView(
                    symbol: "checklist",
                    title: "Your shopping list is empty",
                    message: "Add things you need. Everyone in \(app.household?.name ?? "your household") sees the list, and anyone can say they'll grab it.",
                    primaryTitle: "Add an item", primary: { addFocused = true }
                )
                .padding(.top, 80)
            } else if !search.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search your list")
        .sensoryFeedback(.selection, trigger: toggles)
        .navigationTitle("Shopping list")
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(isSelecting)
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
            } else if !app.shoppingList.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                SelectionActionBar(count: selection.count) {
                    if selectedEntries.contains(where: { !$0.done }) {
                        Button("Bought", systemImage: "checkmark.circle") {
                            app.setShoppingItems(selectedEntries, done: true)
                            endSelecting()
                        }
                        Button("I'll get", systemImage: "hand.raised") {
                            app.claimShoppingItems(selectedEntries)
                            endSelecting()
                        }
                    } else {
                        Button("To buy", systemImage: "arrow.uturn.backward") {
                            app.setShoppingItems(selectedEntries, done: false)
                            endSelecting()
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        app.deleteShoppingItems(selectedEntries)
                        endSelecting()
                    }
                    .tint(.red)
                }
                .labelStyle(.iconOnly)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isSelecting)
        .onChange(of: app.shoppingList.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .expandsTabBarOnScrollUp()
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    private func row(_ entry: ShoppingListItem) -> some View {
        Button {
            toggles += 1
            app.toggleShoppingItem(entry)
        } label: {
            ShoppingRow(entry: entry, estimate: estimate(entry), showsCheckbox: true)
        }
        .buttonStyle(.plain)
        .tag(entry.id)
        .accessibilityValue(entry.done ? "Bought" : "Not bought")
        .accessibilityHint(entry.done ? "Moves it back to the list" : "Marks it bought")
        .accessibilityAddTraits(entry.done ? .isSelected : [])
        .contextMenu {
            if !entry.done {
                Button(entry.claimedBy == nil ? "I'll get it" : "Let go", systemImage: "hand.raised") {
                    app.toggleClaim(entry)
                }
            }
            Button("Select", systemImage: "checkmark.circle") {
                isSelecting = true
                selection = [entry.id]
            }
            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteShoppingItem(entry) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteShoppingItem(entry) }
            Button(entry.done ? "To buy" : "Bought", systemImage: entry.done ? "arrow.uturn.backward" : "checkmark.circle") {
                toggles += 1
                app.toggleShoppingItem(entry)
            }
            .tint(.green)
        }
        .swipeActions(edge: .leading) {
            if !entry.done {
                Button(entry.claimedBy == nil ? "I'll get it" : "Let go", systemImage: "hand.raised") {
                    app.toggleClaim(entry)
                }
                .tint(.orange)
            }
        }
    }

    private var budgetSection: some View {
        let estimates = open.map(estimate)
        let total = estimates.map(\.price).reduce(0, +)
        let typical = estimates.filter { !$0.paid }.count
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ShoppingEstimate.totalText(estimates)).font(.title3.bold()).monospacedDigit()
                    Spacer()
                    if let hh = bank.household {
                        let left = hh.weekLeft
                        Text(left >= 0 ? "\(left.usd) left this week"
                                       : "\((-left).usd) over budget")
                            .font(.subheadline)
                            .foregroundStyle(left < total ? Tone.warning.color : .secondary)
                    }
                }
                if let hh = bank.household {
                    BudgetBar(spent: hh.week_spend + total, budget: hh.budget)
                    if hh.weekLeft >= 0 && hh.weekLeft < total {
                        Text("This trip would put you \((total - hh.weekLeft).usd) over this week's budget.")
                            .font(.caption).foregroundStyle(Tone.warning.color)
                    } else if let streak = hh.streak {
                        StreakLine(streak: streak)
                    }
                }
            }
            .padding(.vertical, 4)
            NavigationLink {
                BasketComparisonView(entries: open)
            } label: {
                Label("Compare prices at nearby stores", systemImage: "storefront")
            }
        } footer: {
            Text(typical == 0 ? "Prices are what you last paid on your card."
                 : "Prices are what you last paid on your card. “Typical price” (~) is a sample estimate for things you haven't bought yet, not a store's price.")
        }
    }

    private func add() {
        let name = newItem.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.addToShoppingList(name: name, barcode: nil)
        newItem = ""
    }
}

/// A shopping-list entry laid out like a fridge row: food icon, name with status icons, a detail line,
/// and the bought checkbox where the fridge shows the count.
struct ShoppingRow: View {
    @Environment(AppState.self) private var app
    var entry: ShoppingListItem
    var estimate: ShoppingEstimate
    var showsCheckbox: Bool

    private var categoryID: String { app.services.shelfLife.categoryID(forName: entry.name) }

    /// The same product already in the fridge (by barcode, else by name), for its photo and count.
    private var inFridge: FridgeItem? {
        if let code = entry.barcode.map(Barcode.normalize),
           let match = app.items.first(where: { $0.normalizedBarcode == code }) { return match }
        return app.items.first { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
    }

    var body: some View {
        let fridge = inFridge
        HStack(spacing: 12) {
            CategoryThumbnail(categoryID: fridge?.category ?? categoryID, imageURL: fridge?.imageURL)
                .opacity(entry.done ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(entry.done ? Color.green : entry.claimedBy != nil ? .blue : .orange)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .strikethrough(entry.done)
                        .foregroundStyle(entry.done ? .secondary : .primary)
                    if entry.claimedBy != nil && !entry.done {
                        Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(Tone.info.color)
                            .accessibilityHidden(true)
                    }
                    if entry.barcode != nil {
                        Image(systemName: "barcode").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Scanned product")
                    }
                }
                detailLine(fridge: fridge)
            }
            Spacer(minLength: 4)
            if !entry.done {
                Text(estimate.priceText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if showsCheckbox {
                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(entry.done ? Tone.success.color : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detailLine(fridge: FridgeItem?) -> some View {
        HStack(spacing: 4) {
            if entry.done {
                Text("Bought")
            } else if let who = entry.claimedBy {
                Text("\(who)'s grabbing it").foregroundStyle(Tone.info.color)
            } else {
                Text(app.services.shelfLife.category(id: fridge?.category ?? categoryID)?.name ?? "Grocery")
            }
            if let fridge, fridge.count > 0, !entry.done {
                Text("·")
                Text("\(fridge.count) in fridge")
            }
            if !entry.done, let badge = estimate.badge {
                StatusChip(text: badge, tone: .warning)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
