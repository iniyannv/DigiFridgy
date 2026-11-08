import SwiftUI

struct ItemDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let itemId: String

    @State private var showRecall = false
    @State private var showDatePicker = false
    @State private var confirmDelete = false
    @State private var showEdit = false

    var body: some View {
        if let item = app.item(id: itemId) {
            content(item)
        } else {
            ContentUnavailableView("Item removed", systemImage: "refrigerator",
                                   description: Text("This item is no longer in the fridge."))
        }
    }

    private func content(_ item: FridgeItem) -> some View {
        let allergens = Allergen.from(tags: item.allergens)
        let hits = item.allergenHits(for: app.userAllergens)

        return List {
            Section {
                HStack(spacing: 16) {
                    ItemThumbnail(item: item, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.title3.bold())
                        if let brand = item.brand { Text(brand).foregroundStyle(.secondary) }
                        Text(app.shelfLife.displayName(for: item.category))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }

            if let recall = item.recallFlag {
                Section {
                    Button { showRecall = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recall.title).bold()
                                Text(recall.reason).font(.caption).lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: recall.isPossible ? "questionmark.diamond.fill" : "exclamationmark.octagon.fill")
                        }
                        .foregroundStyle(.white)
                    }
                    .listRowBackground(recall.isPossible ? Color.orange : Color.red)
                }
            }

            if !hits.isEmpty {
                Section {
                    Label("Contains \(hits.map(\.displayName).joined(separator: ", ")) — on your allergen list",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .bold()
                }
            }

            Section("In the fridge") {
                Stepper(value: Binding(
                    get: { item.count },
                    set: { newValue in Task { await app.adjustCount(item, by: newValue - item.count) } }
                ), in: 0...99) {
                    HStack {
                        Text("Count")
                        Spacer()
                        Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Button {
                    showDatePicker = true
                } label: {
                    HStack {
                        Text("Expires").foregroundStyle(.primary)
                        Spacer()
                        ExpiryLabel(item: item)
                    }
                }
                if item.expiryIsEstimated {
                    Text("Estimated from typical fridge life for \(app.shelfLife.displayName(for: item.category).lowercased()) (\(app.shelfLife.fridgeDays(for: item.category)) days). Tap to set the date on the label.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Added", value: item.addedAt.formatted(date: .abbreviated, time: .omitted))
                if item.isCardPurchase {
                    LabeledContent("Bought with card", value: item.store ?? "Card purchase")
                    if let price = item.price {
                        LabeledContent("Price", value: "\(price.formatted(.currency(code: "USD"))) each")
                    }
                } else {
                    LabeledContent("Source", value: item.source == .barcode ? "Barcode scan" : "Receipt scan")
                }
            }

            Section("Nutrition") {
                NutriScoreBadge(app.shelfLife.nutriScore(for: item))
                    .padding(.vertical, 4)
                if let nutrition = item.nutrition {
                    NutritionLabelView(nutrition: nutrition)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } else {
                    Text("No nutrition data for this item.").foregroundStyle(.secondary)
                }
                Button("Edit nutrition facts", systemImage: "pencil") { showEdit = true }
            }

            Section("Allergens") {
                AllergenChips(allergens: allergens, highlighted: app.userAllergens)
                    .padding(.vertical, 4)
            }

            Section {
                NavigationLink {
                    PriceComparisonView(item: item)
                } label: {
                    Label("Find cheapest nearby", systemImage: "dollarsign.circle")
                }
                if item.barcode != nil {
                    Toggle(isOn: Binding(get: { app.isWatched(item) }, set: { _ in app.toggleWatch(item) })) {
                        Label("Watch price", systemImage: "bell.badge")
                    }
                }
            } header: {
                Text("Prices")
            } footer: {
                if item.barcode != nil {
                    Text("Watched items are checked in the background; you'll get a notification when the price drops.")
                }
            }

            Section {
                Button("Add to shopping list", systemImage: "checklist") {
                    app.addToShoppingList(name: item.name, barcode: item.barcode)
                }
                Button("Remove from fridge", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) { ItemEditSheet(item: item) }
        .sheet(isPresented: $showRecall) { RecallDetailSheet(item: item) }
        .sheet(isPresented: $showDatePicker) {
            ExpiryPickerSheet(initial: item.expiresAt) { date in
                Task { await app.setExpiry(item, to: date) }
            }
        }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await app.delete(item)
                    dismiss()
                }
            }
        }
    }
}

struct ExpiryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var date: Date
    var onSave: (Date) -> Void

    init(initial: Date, onSave: @escaping (Date) -> Void) {
        _date = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            DatePicker("Expiry date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Date on the label")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(date)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RecallDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    var item: FridgeItem

    var body: some View {
        NavigationStack {
            List {
                if let recall = item.recallFlag {
                    Section {
                        if recall.isPossible {
                            Label("Possible recall: check the brand", systemImage: "questionmark.diamond.fill")
                                .foregroundStyle(.orange).bold()
                            Text("This notice matches the product name only. Compare the brand and codes on your package with the FDA notice.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Do not eat this product", systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red).bold()
                        }
                    }
                    Section("Reason") { Text(recall.reason) }
                    Section("Details") {
                        LabeledContent("Recall ID", value: recall.recallId)
                        LabeledContent("Date", value: recall.date.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Product", value: [item.brand, item.name].compactMap { $0 }.joined(separator: " "))
                    }
                    if let url = recall.url.flatMap(URL.init(string:)) {
                        Section {
                            Link(destination: url) {
                                Label("View FDA recall notices", systemImage: "safari")
                            }
                        }
                    }
                    Section {
                        Button("Not my product", systemImage: "hand.raised") {
                            Task {
                                await app.dismissRecall(item)
                                dismiss()
                            }
                        }
                        Button("Discard item", systemImage: "trash", role: .destructive) {
                            Task {
                                await app.delete(item)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
