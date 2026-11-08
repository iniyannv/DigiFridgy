import SwiftUI

/// A recipe at a glance: what it uses from the fridge, every ingredient marked have / pantry / missing,
/// one tap to put the missing ones on the shopping list, and the full recipe on its site.
struct RecipeDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var saved = SavedRecipeStore.shared
    @State private var openURL: IdentifiableURL?

    var scored: ScoredRecipe

    private var recipe: Recipe { scored.recipe }
    private var sourceURL: URL? { URL(string: recipe.sourceURL) }
    private var missingNames: [String] { scored.missing.map(\.capitalizedFirst) }
    /// Open shopping-list entries, lowercased, so rows can show what's already on the list.
    private var onList: Set<String> { Set(app.shoppingList.filter { !$0.done }.map { $0.name.lowercased() }) }
    private var allMissingOnList: Bool { scored.missing.allSatisfy { onList.contains($0.lowercased()) } }

    enum Availability { case have, pantry, missing }

    var body: some View {
        NavigationStack {
            List {
                header
                if !scored.uses.isEmpty { fromFridge }
                ingredientsSection
                if !scored.missing.isEmpty {
                    Section {
                        if allMissingOnList {
                            Label("Missing items are on the shopping list", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Tone.success.color)
                        } else {
                            Button {
                                app.addToShoppingList(names: missingNames)
                            } label: {
                                Label("Add \(scored.missing.count) missing to shopping list", systemImage: "cart.badge.plus")
                            }
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        let nowSaved = saved.toggle(recipe)
                        app.showMessage(nowSaved ? "Saved" : "Removed from saved")
                    } label: {
                        Label(saved.isSaved(recipe) ? "Remove from saved" : "Save",
                              systemImage: saved.isSaved(recipe) ? "heart.fill" : "heart")
                    }
                    .tint(.pink)
                    if let sourceURL {
                        ShareLink(item: sourceURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let sourceURL {
                    Button {
                        openURL = IdentifiableURL(url: sourceURL)
                    } label: {
                        Label("Open full recipe", systemImage: "safari")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .sheet(item: $openURL) { SafariView(url: $0.url).ignoresSafeArea() }
        }
        // Sheets cover the app's toast layer; show confirmations here too.
        .toastOverlay()
    }

    // MARK: Sections

    private var header: some View {
        Section {
            RecipeImage(urlString: recipe.largeImageURL ?? recipe.imageURL, iconFont: .largeTitle)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipped()
                .listRowInsets(EdgeInsets())

            VStack(alignment: .leading, spacing: 10) {
                Text(RecipeCard.displayTitle(recipe.title))
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    StatusChip(text: recipe.difficulty.label, tone: recipe.difficulty.tone)
                        .fixedSize()
                        .accessibilityLabel("Difficulty: \(recipe.difficulty.label)")
                    if let source = recipe.sourceName {
                        Text("From \(source)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                stats
                if !tags.isEmpty {
                    FlowTags(tags: tags)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat(value: recipe.totalTimeMinutes.map { "\(Int($0))" } ?? "–", unit: "min", label: "Total time")
            Divider().frame(height: 32)
            stat(value: recipe.caloriesPerServing.map { "\(Int($0.rounded()))" } ?? "–", unit: "kcal", label: "Per serving")
            Divider().frame(height: 32)
            stat(value: recipe.servings.map { "\(Int($0))" } ?? "–", unit: "", label: "Servings")
            Divider().frame(height: 32)
            stat(value: "\(scored.missing.count)", unit: "", label: "Missing")
        }
        .padding(.vertical, 6)
    }

    private func stat(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline.monospacedDigit())
                if !unit.isEmpty && value != "–" { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Meal, dish, cuisine and the most useful diet labels.
    private var tags: [String] {
        let interesting: Set<String> = ["vegetarian", "vegan", "pescatarian", "keto-friendly", "gluten-free",
                                        "dairy-free", "high-protein", "low-carb", "low-fat"]
        var tags = (recipe.mealTypes ?? []) + (recipe.dishTypes ?? []) + (recipe.cuisineTypes ?? [])
        tags += ((recipe.dietLabels ?? []) + (recipe.healthLabels ?? [])).filter { interesting.contains($0.lowercased()) }
        var seen = Set<String>()
        return tags.map { $0.replacingOccurrences(of: "/", with: " / ").capitalizedFirst }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private var fromFridge: some View {
        Section("From your fridge") {
            ForEach(scored.uses, id: \.itemName) { match in
                HStack {
                    Text(match.itemName.capitalizedFirst)
                    Spacer()
                    Text(match.expiryLabel)
                        .font(.subheadline)
                        .foregroundStyle(match.isExpiringSoon ? Tone.warning.color : .secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var ingredientsSection: some View {
        Section {
            ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                ingredientRow(ingredient)
            }
        } header: {
            Text("Ingredients (\(recipe.ingredients.count))")
        } footer: {
            Text("Pantry staples like salt, oil, sugar and flour are assumed and not counted as missing.")
        }
    }

    private func ingredientRow(_ ingredient: RecipeIngredient) -> some View {
        let availability = availability(of: ingredient)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch availability {
                case .have: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success.color)
                case .pantry: Image(systemName: "cabinet").foregroundStyle(.secondary)
                case .missing: Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            Text(ingredient.text.isEmpty ? ingredient.food : ingredient.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if availability == .missing && onList.contains(ingredient.food.lowercased()) {
                Text("On list").font(.caption.weight(.semibold)).foregroundStyle(Tone.success.color)
            } else if availability == .missing {
                Button {
                    app.addToShoppingList(names: [ingredient.food.capitalizedFirst])
                } label: {
                    Label("Add \(ingredient.food) to shopping list", systemImage: "cart.badge.plus")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(availability == .have ? "In your fridge" : availability == .pantry ? "Pantry staple" : "Missing")
    }

    private func availability(of ingredient: RecipeIngredient) -> Availability {
        let food = ingredient.food.lowercased().trimmingCharacters(in: .whitespaces)
        if food.isEmpty || RecipeScorer.pantryStaples.contains(food) { return .pantry }
        return scored.missing.contains(food) ? .missing : .have
    }
}

/// Recipe tags on one scrolling line.
private struct FlowTags: View {
    var tags: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    StatusChip(text: tag)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
