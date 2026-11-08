import SwiftUI

/// Food category picker shared by scan confirmation and item editing.
struct CategoryPicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: String

    var body: some View {
        Picker("Category", selection: $selection) {
            ForEach(app.shelfLife.categories) { category in
                Text("\(CategoryStyle.emoji(for: category.id)) \(category.name)").tag(category.id)
            }
            Text("🛒 Other").tag(ShelfLifeService.unknownCategoryID)
        }
    }
}

/// Editable nutrition facts (per serving). Rows for an optional `Nutrition`; clearing every field sets it to nil.
struct NutritionEditorRows: View {
    @Binding var nutrition: Nutrition?

    var body: some View {
        LabeledContent("Serving size") {
            TextField("e.g. 1 cup (240 ml)", text: Binding(
                get: { nutrition?.servingSize ?? "" },
                set: { value in update { $0.servingSize = value.isEmpty ? nil : value } }))
                .multilineTextAlignment(.trailing)
        }
        field("Calories", unit: "kcal", \.kcal)
        field("Total fat", unit: "g", \.fat)
        field("Sodium", unit: "mg", \.sodium)
        field("Total carbs", unit: "g", \.carbs)
        field("Dietary fiber", unit: "g", \.fiber)
        field("Total sugars", unit: "g", \.sugar)
        field("Protein", unit: "g", \.protein)
    }

    private func field(_ title: String, unit: String, _ keyPath: WritableKeyPath<Nutrition, Double?>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("—", value: Binding(
                    get: { nutrition?[keyPath: keyPath] },
                    set: { value in update { $0[keyPath: keyPath] = value } }),
                          format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .leading)
            }
        }
    }

    private func update(_ change: (inout Nutrition) -> Void) {
        var value = nutrition ?? Nutrition()
        change(&value)
        nutrition = value.isEmpty && value.servingSize == nil ? nil : value
    }
}

/// Edit name, brand, category and nutrition of an item already in the fridge.
struct ItemEditSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: FridgeItem

    @State private var name: String
    @State private var brand: String
    @State private var category: String
    @State private var nutrition: Nutrition?
    @State private var isSaving = false

    init(item: FridgeItem) {
        self.item = item
        _name = State(initialValue: item.name)
        _brand = State(initialValue: item.brand ?? "")
        _category = State(initialValue: item.category)
        _nutrition = State(initialValue: item.nutrition)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, axis: .vertical)
                    TextField("Brand (optional)", text: $brand)
                    CategoryPicker(selection: $category)
                } header: {
                    Text("Product")
                } footer: {
                    if item.expiryIsEstimated, category != item.category {
                        Text("The estimated expiry will be updated for the new category.")
                    }
                }

                Section {
                    NutritionEditorRows(nutrition: $nutrition)
                } header: {
                    Text("Nutrition facts (per serving)")
                } footer: {
                    if let code = item.barcode {
                        Text("Your changes are saved for barcode \(code) and used every time you scan it again.")
                    }
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await app.updateDetails(item, name: name, brand: brand, category: category,
                                                                nutrition: nutrition)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }
}
