import SwiftUI

/// Post-scan confirmation: editable name, brand, category, nutrition; count; estimated expiry (overridable).
/// Edits to a barcode product are remembered and re-applied the next time it's scanned.
struct ItemConfirmationView: View {
    @Environment(AppState.self) private var app
    @State var draft: FridgeItem
    var usesSavedCorrections: Bool
    /// True while the parent is saving: the button shows progress and can't be tapped twice.
    var isSaving: Bool
    var onSave: (FridgeItem) -> Void
    var onRescan: () -> Void

    @State private var showDatePicker = false
    @State private var editingNutrition = false

    init(draft: FridgeItem, usesSavedCorrections: Bool = false, isSaving: Bool = false,
         onSave: @escaping (FridgeItem) -> Void, onRescan: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.usesSavedCorrections = usesSavedCorrections
        self.isSaving = isSaving
        self.onSave = onSave
        self.onRescan = onRescan
    }

    private var brandBinding: Binding<String> {
        Binding(get: { draft.brand ?? "" },
                set: { draft.brand = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ItemThumbnail(item: draft, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.name.isEmpty ? "Unnamed item" : draft.name).font(.headline)
                        if let brand = draft.brand { Text(brand).font(.subheadline).foregroundStyle(.secondary) }
                        if let code = draft.barcode { Text(code).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }
                }
                if usesSavedCorrections {
                    Label("Using your saved corrections for this barcode", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(Tone.success.color)
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField("Product name", text: $draft.name, axis: .vertical)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Brand") {
                    TextField("Optional", text: brandBinding)
                        .multilineTextAlignment(.trailing)
                }
                CategoryPicker(selection: $draft.category)
            } header: {
                Text("Product")
            } footer: {
                if draft.barcode != nil {
                    Text("Scanned info not right? Fix it here. Your changes are remembered for this barcode.")
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

            Section {
                if editingNutrition {
                    NutritionEditorRows(nutrition: $draft.nutrition)
                } else {
                    if let kcal = draft.nutrition?.kcal {
                        LabeledContent("Calories", value: "\(Int(kcal.rounded())) per \(draft.nutrition?.servingSize ?? "serving")")
                    } else {
                        Text("No nutrition facts found.").foregroundStyle(.secondary)
                    }
                    Button("Edit nutrition facts", systemImage: "pencil") { editingNutrition = true }
                }
            } header: {
                Text("Nutrition (per serving)")
            }

            Section("Details") {
                NutriScoreBadge(app.shelfLife.nutriScore(for: draft))
                AllergenChips(allergens: Allergen.from(tags: draft.allergens), highlighted: app.userAllergens)
            }

            Section {
                Button {
                    onSave(draft)
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView() }
                        Text(isSaving ? "Adding…" : "Add to fridge").bold()
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                Button("Scan a different item", action: onRescan)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: draft.category) { oldCategory, newCategory in
            if draft.expiryIsEstimated {
                draft.expiresAt = app.shelfLife.estimatedExpiry(categoryID: newCategory)
            }
            if draft.allergens == Allergen.implied(byCategory: oldCategory).map(\.rawValue) {
                draft.allergens = Allergen.implied(byCategory: newCategory).map(\.rawValue)
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
