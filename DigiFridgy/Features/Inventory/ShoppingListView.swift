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
    @FocusState private var addFocused: Bool

    private func estimate(_ entry: ShoppingListItem) -> ShoppingEstimate {
        ShoppingEstimate.estimate(name: entry.name, items: app.items) { name in
            app.services.mockPrices.referencePrice(categoryID: app.services.shelfLife.categoryID(forName: name))
        }
    }

    private var open: [ShoppingListItem] { app.shoppingList.filter { !$0.done } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an item", text: $newItem)
                        .focused($addFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !open.isEmpty { budgetSection }
            if !app.shoppingList.isEmpty {
                Section {
                    ForEach(app.shoppingList) { entry in
                        Button {
                            toggles += 1
                            app.toggleShoppingItem(entry)
                        } label: {
                            Label {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .strikethrough(entry.done)
                                            .foregroundStyle(entry.done ? .secondary : .primary)
                                        if let who = entry.claimedBy, !entry.done {
                                            StatusChip(text: "\(who)'s grabbing it", tone: .info, systemImage: "hand.raised.fill")
                                        }
                                    }
                                    Spacer()
                                    if !entry.done {
                                        let e = estimate(entry)
                                        if let badge = e.badge {
                                            StatusChip(text: badge, tone: .warning)
                                        }
                                        Text(e.priceText)
                                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(entry.done ? Tone.success.color : .secondary)
                            }
                        }
                        .accessibilityValue(entry.done ? "Bought" : "Not bought")
                        .accessibilityAddTraits(entry.done ? .isSelected : [])
                        .contextMenu {
                            if !entry.done {
                                Button(entry.claimedBy == nil ? "I'll get it" : "Let go", systemImage: "hand.raised") {
                                    app.toggleClaim(entry)
                                }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteShoppingItem(entry) }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteShoppingItem(entry) }
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
                } footer: {
                    Text("Shared with everyone in \(app.household?.name ?? "your household"), and with the household's iMessage chat. Swipe right or touch and hold to say you'll get something.")
                }
            }
        }
        .overlay {
            if app.shoppingList.isEmpty {
                EmptyStateView(
                    symbol: "checklist",
                    title: "Your shopping list is empty",
                    message: "Add things you need. Everyone in \(app.household?.name ?? "your household") sees the list, and anyone can say they'll grab it.",
                    primaryTitle: "Add an item", primary: { addFocused = true }
                )
                .padding(.top, 80)
            }
        }
        .sensoryFeedback(.selection, trigger: toggles)
        .navigationTitle("Shopping list")
        .navigationBarTitleDisplayMode(.large)
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
