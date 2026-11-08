import SwiftUI

/// Post-scan confirmation: name, image, count, estimated expiry (overridable).
struct ItemConfirmationView: View {
    @Environment(AppState.self) private var app
    @State var draft: FridgeItem
    var onSave: (FridgeItem) -> Void
    var onRescan: () -> Void

    @State private var showDatePicker = false

    init(draft: FridgeItem, onSave: @escaping (FridgeItem) -> Void, onRescan: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onRescan = onRescan
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ItemThumbnail(item: draft, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $draft.name, axis: .vertical)
                            .font(.headline)
                        if let brand = draft.brand { Text(brand).font(.subheadline).foregroundStyle(.secondary) }
                        if let code = draft.barcode { Text(code).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }
                }
            }

            Section {
                Stepper(value: $draft.count, in: 1...99) {
                    HStack {
                        Text("Count")
                        Spacer()
                        Text("\(draft.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Picker("Category", selection: $draft.category) {
                    ForEach(app.shelfLife.categories) { category in
                        Text("\(CategoryStyle.emoji(for: category.id)) \(category.name)").tag(category.id)
                    }
                    Text("🛒 Other").tag(ShelfLifeService.unknownCategoryID)
                }
                .onChange(of: draft.category) { _, newCategory in
                    if draft.expiryIsEstimated {
                        draft.expiresAt = app.shelfLife.estimatedExpiry(categoryID: newCategory)
                    }
                }
                Button {
                    showDatePicker = true
                } label: {
                    HStack {
                        Text("Expires").foregroundStyle(.primary)
                        Spacer()
                        ExpiryLabel(item: draft)
                        Image(systemName: "calendar").foregroundStyle(.tint)
                    }
                }
            } footer: {
                if draft.expiryIsEstimated {
                    Text("“Est.” = typical fridge life for this kind of food. Tap to enter the date printed on the package.")
                }
            }

            Section("Details") {
                NutriScoreBadge(grade: draft.nutriScore)
                AllergenChips(allergens: Allergen.from(tags: draft.allergens), highlighted: app.userAllergens)
                if let kcal = draft.nutrition?.kcal {
                    LabeledContent("Calories", value: "\(Int(kcal)) per \(draft.nutrition?.servingSize ?? "serving")")
                }
            }

            Section {
                Button {
                    onSave(draft)
                } label: {
                    Text("Add to fridge").bold().frame(maxWidth: .infinity)
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Scan a different item", action: onRescan)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showDatePicker) {
            ExpiryPickerSheet(initial: draft.expiresAt) { date in
                draft.expiresAt = date
                draft.expiryIsEstimated = false
            }
        }
    }
}
