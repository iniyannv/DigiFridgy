import SwiftUI

struct ShoppingListView: View {
    @Environment(AppState.self) private var app
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an item", text: $newItem)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
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
                                Text(entry.name)
                                    .strikethrough(entry.done)
                                    .foregroundStyle(entry.done ? .secondary : .primary)
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

    private func add() {
        let name = newItem.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.addToShoppingList(name: name, barcode: nil)
        newItem = ""
    }
}
