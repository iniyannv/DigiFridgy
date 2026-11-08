import SwiftUI

struct ShoppingListView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank
    @State private var newItem = ""

    /// Per-unit price for a list entry: what the household last paid on the card, else the category's typical price.
    private func estimate(_ entry: ShoppingListItem) -> (price: Double, paid: Bool) {
        let name = entry.name.lowercased()
        let paid = app.items
            .filter { $0.price != nil && ($0.name.lowercased() == name || $0.name.lowercased().contains(name)
                                          || name.contains($0.name.lowercased())) }
            .max { $0.addedAt < $1.addedAt }?.price
        if let paid { return (paid, true) }
        let category = app.services.shelfLife.categoryID(forName: entry.name)
        return (app.services.mockPrices.referencePrice(categoryID: category), false)
    }

    private var open: [ShoppingListItem] { app.shoppingList.filter { !$0.done } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an item", text: $newItem)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !open.isEmpty { budgetSection }
            if app.shoppingList.isEmpty {
                ContentUnavailableView("Nothing to buy", systemImage: "checklist",
                                       description: Text("Items you run out of can be added here."))
            } else {
                Section {
                    ForEach(app.shoppingList) { entry in
                        Button {
                            app.toggleShoppingItem(entry)
                        } label: {
                            Label {
                                HStack {
                                    Text(entry.name)
                                        .strikethrough(entry.done)
                                        .foregroundStyle(entry.done ? .secondary : .primary)
                                    Spacer()
                                    if !entry.done {
                                        let e = estimate(entry)
                                        Text("\(e.paid ? "" : "~")\(e.price.formatted(.currency(code: "USD")))")
                                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(entry.done ? .green : .secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteShoppingItem(entry) }
                        }
                    }
                } footer: {
                    Text("Shared with everyone in \(app.household?.name ?? "your household").")
                }
            }
        }
        .navigationTitle("Shopping list")
    }

    private var budgetSection: some View {
        let estimates = open.map(estimate)
        let total = estimates.map(\.price).reduce(0, +)
        let typical = estimates.filter { !$0.paid }.count
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("About \(total.formatted(.currency(code: "USD")))").font(.title3.bold()).monospacedDigit()
                    Spacer()
                    if let hh = bank.household {
                        let left = hh.weekLeft
                        Text(left >= 0 ? "\(left.formatted(.currency(code: "USD"))) left this week"
                                       : "\((-left).formatted(.currency(code: "USD"))) over budget")
                            .font(.subheadline)
                            .foregroundStyle(left < total ? .orange : .secondary)
                    }
                }
                if let hh = bank.household {
                    BudgetBar(spent: hh.week_spend + total, budget: hh.budget)
                    if hh.weekLeft >= 0 && hh.weekLeft < total {
                        Text("This trip would put you \((total - hh.weekLeft).formatted(.currency(code: "USD"))) over this week's budget.")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let streak = hh.streak {
                        StreakLine(streak: streak)
                    }
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text(typical == 0 ? "Prices are what you last paid on your card."
                 : "Prices are what you last paid on your card; ~ marks a typical price for things you haven't bought yet.")
        }
    }

    private func add() {
        let name = newItem.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.addToShoppingList(name: name, barcode: nil)
        newItem = ""
    }
}
