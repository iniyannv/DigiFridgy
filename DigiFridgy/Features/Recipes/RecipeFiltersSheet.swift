import SwiftUI

/// All recipe filters in one place. Edits a draft and applies it on "Show recipes", so trying options
/// doesn't fire a search per tap.
struct RecipeFiltersSheet: View {
    @Binding var filters: RecipeFilters
    var allergens: [Allergen]

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecipeFilters

    init(filters: Binding<RecipeFilters>, allergens: [Allergen]) {
        _filters = filters
        self.allergens = allergens
        _draft = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Meal", selection: $draft.meal) {
                        Text("Any").tag(MealType?.none)
                        ForEach(MealType.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Dish", selection: $draft.dish) {
                        Text("Any").tag(DishType?.none)
                        ForEach(DishType.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Cuisine", selection: $draft.cuisine) {
                        Text("Any").tag(Cuisine?.none)
                        ForEach(Cuisine.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                }

                Section {
                    Picker("Ready in", selection: $draft.maxMinutes) {
                        Text("Any").tag(Int?.none)
                        ForEach(RecipeFilters.timeChoices, id: \.self) { minutes in
                            Text(minutes == 60 ? "1 hr" : "\(minutes) min").tag(Optional(minutes))
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Ready in")
                }

                Section {
                    Picker("Missing ingredients", selection: $draft.maxMissing) {
                        Text("Any").tag(Int?.none)
                        ForEach(RecipeFilters.missingChoices, id: \.self) { count in
                            Text(count == 0 ? "None" : "≤ \(count)").tag(Optional(count))
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Ingredients you don't have")
                } footer: {
                    Text("Pantry staples like salt, oil, sugar and flour don't count.")
                }

                Section {
                    ForEach(DietOption.allCases) { diet in
                        Toggle(diet.title, isOn: Binding(
                            get: { draft.diets.contains(diet) },
                            set: { on in
                                if on { draft.diets.insert(diet) } else { draft.diets.remove(diet) }
                            }))
                    }
                } header: {
                    Text("Diet")
                } footer: {
                    if allergens.isEmpty {
                        Text("Set allergens in Settings to always leave them out.")
                    } else {
                        Text("Your allergens (\(allergens.map(\.displayName).joined(separator: ", "))) are always left out. Change them in Settings.")
                    }
                }

                if !draft.isEmpty {
                    Section {
                        Button("Reset all filters", role: .destructive) { draft = RecipeFilters() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show recipes") {
                        filters = draft
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.large])
    }
}
