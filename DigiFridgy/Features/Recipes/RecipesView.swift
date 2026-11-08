import SwiftUI

/// Recipes ranked by "use expiring food first", with search, ingredient picking, filters, sorting and saving.
struct RecipesView: View {
    @Environment(AppState.self) private var app
    @State private var saved = SavedRecipeStore.shared

    @State private var scope: Scope = .forYou
    @State private var searchText = ""
    /// The search actually run (set on submit, so typing doesn't spend API calls).
    @State private var submittedSearch = ""
    /// Fridge ingredients picked to cook with, in the order they were picked.
    @State private var picked: [String] = []
    @State private var filters = RecipeFilters()
    @State private var sort: RecipeSort = .bestMatch

    @State private var fetched: [Recipe] = []
    @State private var fetchedFor: RecipeSearchRequest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    @State private var showFilters = false
    @State private var detail: ScoredRecipe?

    enum Scope: Hashable { case forYou, saved }

    static let searchIdeas = ["Pasta", "Tacos", "Soup", "Stir fry", "Salad", "Curry", "Omelette", "Smoothie"]

    // MARK: Derived state

    private var allergens: [Allergen] { Allergen.allCases.filter(app.userAllergens.contains) }

    private var ingredients: [RecipeScorer.Ingredient] {
        Array(app.services.scorer.ingredients(in: app.items).prefix(16))
    }

    private var request: RecipeSearchRequest {
        RecipeSearchRequest(
            queries: RecipeSearchRequest.queries(text: submittedSearch, ingredients: picked,
                                                 expiringQueries: app.services.scorer.queries(for: app.items)),
            allergenLabels: allergens.map(\.edamamHealthLabel),
            filters: filters)
    }

    /// What the list shows: fetched (or saved) recipes, scored against the fridge, filtered and sorted.
    private var shown: [ScoredRecipe] {
        var source = scope == .saved ? saved.recipes : fetched
        if scope == .saved {
            let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            if !query.isEmpty {
                source = source.filter { recipe in
                    recipe.title.lowercased().contains(query)
                        || recipe.ingredients.contains { $0.food.lowercased().contains(query) }
                }
            }
        }
        let ranked = app.services.scorer.rank(source, items: app.items).filter { filters.admits($0) }
        return sort.sorted(ranked)
    }

    // MARK: Body

    var body: some View {
        let shown = self.shown
        NavigationStack {
            List {
                controls
                results(shown)
            }
            .listSectionSpacing(.compact)
            .expandsTabBarOnScrollUp()
            .navigationTitle("Recipes")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: scope == .saved ? "Search saved recipes" : "Search recipes, e.g. tacos")
            .searchSuggestions {
                if scope == .forYou && searchText.isEmpty {
                    Section("Ideas") {
                        ForEach(Self.searchIdeas, id: \.self) { idea in
                            Label(idea, systemImage: "magnifyingglass").searchCompletion(idea)
                        }
                    }
                }
            }
            .onSubmit(of: .search) { submittedSearch = searchText.trimmingCharacters(in: .whitespaces) }
            .onChange(of: searchText) { _, text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    submittedSearch = ""
                } else if Self.searchIdeas.contains(trimmed), trimmed != submittedSearch {
                    // Picking a suggestion fills the field; run it right away.
                    submittedSearch = trimmed
                }
            }
            .toolbar { sortMenu }
            .refreshable { if scope == .forYou { await load(request, debounce: false) } }
            .task(id: scope == .forYou ? request : nil) {
                guard scope == .forYou else { return }
                // A different search (not just different filters): don't leave the old recipes on screen.
                if let fetchedFor, fetchedFor.queries != request.queries { fetched = [] }
                await load(request, debounce: fetchedFor != nil && !fetched.isEmpty)
            }
            .sheet(isPresented: $showFilters) {
                RecipeFiltersSheet(filters: $filters, allergens: allergens)
            }
            .sheet(item: $detail) { RecipeDetailView(scored: $0) }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        Section {
            Picker("Show", selection: $scope) {
                Text("For your fridge").tag(Scope.forYou)
                Text(saved.recipes.isEmpty ? "Saved" : "Saved (\(saved.recipes.count))").tag(Scope.saved)
            }
            .pickerStyle(.segmented)
            .controlRow(horizontal: 16)

            filterChips.controlRow()

            if scope == .forYou && !ingredients.isEmpty {
                cookWith.controlRow()
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { showFilters = true } label: {
                    FilterChip(title: filters.isEmpty ? "Filters" : "Filters · \(filters.activeCount)",
                               systemImage: "line.3.horizontal.decrease", isOn: !filters.isEmpty)
                }
                .accessibilityLabel(filters.isEmpty ? "Filters" : "Filters, \(filters.activeCount) on")

                Menu {
                    Picker("Meal", selection: $filters.meal) {
                        Text("Any meal").tag(MealType?.none)
                        ForEach(MealType.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
                    }
                } label: {
                    FilterChip(title: filters.meal?.title ?? "Meal", isOn: filters.meal != nil, showsMenu: true)
                }

                Menu {
                    Picker("Ready in", selection: $filters.maxMinutes) {
                        Text("Any time").tag(Int?.none)
                        ForEach(RecipeFilters.timeChoices, id: \.self) { Text("\($0) min or less").tag(Optional($0)) }
                    }
                } label: {
                    FilterChip(title: filters.maxMinutes.map { "≤ \($0) min" } ?? "Time", systemImage: "clock",
                               isOn: filters.maxMinutes != nil, showsMenu: true)
                }

                Button {
                    filters.maxMissing = filters.maxMissing == nil ? 2 : nil
                } label: {
                    FilterChip(title: "Missing ≤ 2", systemImage: "checklist", isOn: filters.maxMissing != nil)
                }

                ForEach([DietOption.vegetarian, .highProtein, .lowCarb]) { diet in
                    Button { toggle(diet) } label: {
                        FilterChip(title: diet.title, isOn: filters.diets.contains(diet))
                    }
                }

                Menu {
                    Picker("Cuisine", selection: $filters.cuisine) {
                        Text("Any cuisine").tag(Cuisine?.none)
                        ForEach(Cuisine.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                } label: {
                    FilterChip(title: filters.cuisine?.title ?? "Cuisine", isOn: filters.cuisine != nil, showsMenu: true)
                }

                if !filters.isEmpty {
                    Button("Clear", role: .destructive) { filters = RecipeFilters() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 36)
                }
            }
            .buttonStyle(.plain)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    private var cookWith: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cook with").font(.subheadline.bold())
                Text(picked.isEmpty ? "What expires first" : picked.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !picked.isEmpty {
                    Button("Reset") { picked = [] }.font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ingredients) { ingredient in
                        let isOn = picked.contains(ingredient.term)
                        Button {
                            if isOn { picked.removeAll { $0 == ingredient.term } } else { picked.append(ingredient.term) }
                        } label: {
                            FilterChip(title: ingredient.term,
                                       emoji: CategoryStyle.emoji(for: ingredient.category),
                                       isOn: isOn,
                                       dot: ingredient.isExpiringSoon ? Tone.warning.color : nil)
                        }
                        .accessibilityLabel(ingredient.term + (ingredient.isExpiringSoon ? ", expiring soon" : ""))
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(RecipeSort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort, \(sort.title)")
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ shown: [ScoredRecipe]) -> some View {
        Section {
            if scope == .saved && saved.recipes.isEmpty {
                emptyRow(EmptyStateView(symbol: "heart",
                                        title: "No saved recipes",
                                        message: "Tap the heart on a recipe, or swipe left on it, to keep it here."))
            } else if scope == .forYou && request.queries.isEmpty {
                emptyRow(EmptyStateView(symbol: "fork.knife",
                                        title: "No ingredients yet",
                                        message: "Add food to your fridge and we'll suggest recipes that use what's expiring first. You can also search for any recipe above."))
            } else if shown.isEmpty && isLoading {
                skeleton
            } else if shown.isEmpty, let errorMessage, scope == .forYou {
                emptyRow(EmptyStateView(symbol: "wifi.exclamationmark",
                                        title: "Couldn't load recipes",
                                        message: errorMessage,
                                        primaryTitle: "Try again", primary: { Task { await load(request, debounce: false) } }))
            } else if shown.isEmpty {
                emptyRow(noMatches)
            } else {
                ForEach(shown) { scored in
                    row(scored)
                }
            }
        } header: {
            if !shown.isEmpty {
                HStack(spacing: 6) {
                    Text(resultsTitle(count: shown.count))
                    if isLoading && scope == .forYou { ProgressView().controlSize(.mini) }
                }
            }
        } footer: {
            if !shown.isEmpty { Text(footerText) }
        }
    }

    private func resultsTitle(count: Int) -> String {
        let noun = count == 1 ? "recipe" : "recipes"
        return "\(count) \(noun) · \(sort.shortTitle)"
    }

    private var footerText: String {
        var parts: [String] = []
        if scope == .saved {
            parts.append("Saved on this device.")
        } else {
            parts.append(app.services.isMock || !Secrets.hasEdamam ? "Sample recipes." : "Recipes from Edamam.")
            if IngredientSwapper.needsAdapting(filters.diets) {
                parts.append("Recipes that usually have meat show what to swap in, like tofu.")
            }
        }
        if !allergens.isEmpty {
            parts.append("Avoiding \(allergens.map(\.displayName).joined(separator: ", ")) (your allergens).")
        }
        return parts.joined(separator: " ")
    }

    private var noMatches: EmptyStateView {
        if !filters.isEmpty {
            return EmptyStateView(symbol: "line.3.horizontal.decrease.circle",
                                  title: "No recipes match these filters",
                                  message: "Try fewer filters or a different search.",
                                  primaryTitle: "Clear filters", primary: { filters = RecipeFilters() })
        }
        if !submittedSearch.isEmpty || (scope == .saved && !searchText.isEmpty) {
            return EmptyStateView(symbol: "magnifyingglass",
                                  title: "No results for “\(scope == .saved ? searchText : submittedSearch)”",
                                  message: "Check the spelling or try a broader search.")
        }
        return EmptyStateView(symbol: "fork.knife",
                              title: "No recipe matches",
                              message: allergens.isEmpty
                                  ? "We couldn't find recipes for what's in your fridge. Pick different ingredients or search above."
                                  : "We couldn't find recipes for what's in your fridge that avoid your allergens. Pick different ingredients or search above.",
                              primaryTitle: "Refresh", primary: { Task { await load(request, debounce: false) } })
    }

    private func emptyRow(_ view: EmptyStateView) -> some View {
        view
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
    }

    private func row(_ scored: ScoredRecipe) -> some View {
        let isSaved = saved.isSaved(scored.recipe)
        return Button { detail = scored } label: {
            RecipeCard(scored: scored, isSaved: isSaved)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows ingredients and what you're missing")
        .swipeActions(edge: .trailing) {
            Button { toggleSaved(scored.recipe) } label: {
                Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
        .contextMenu {
            Button { toggleSaved(scored.recipe) } label: {
                Label(isSaved ? "Remove from saved" : "Save recipe", systemImage: isSaved ? "heart.slash" : "heart")
            }
            if !scored.missing.isEmpty {
                Button { app.addToShoppingList(names: scored.missing.map(\.capitalizedFirst)) } label: {
                    Label("Add \(scored.missing.count) missing to list", systemImage: "cart.badge.plus")
                }
            }
            if let url = URL(string: scored.recipe.sourceURL) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var skeleton: some View {
        ForEach(0..<4, id: \.self) { _ in
            RecipeCard(scored: ScoredRecipe(
                recipe: Recipe(id: UUID().uuidString, title: "Loading a tasty recipe", imageURL: nil, sourceURL: "",
                               sourceName: "Source", ingredients: [], totalTimeMinutes: 20),
                score: 0, uses: [RecipeMatch(itemName: "something", daysUntilExpiry: 1)], missing: ["a", "b"]))
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func toggle(_ diet: DietOption) {
        if filters.diets.contains(diet) { filters.diets.remove(diet) } else { filters.diets.insert(diet) }
    }

    private func toggleSaved(_ recipe: Recipe) {
        let nowSaved = saved.toggle(recipe)
        app.showMessage(nowSaved ? "Saved \(RecipeCard.displayTitle(recipe.title))" : "Removed from saved")
    }

    private func load(_ request: RecipeSearchRequest, debounce: Bool) async {
        guard !request.queries.isEmpty else {
            fetched = []
            fetchedFor = nil
            errorMessage = nil
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        // Loading starts now, so the list never flashes "no matches" for filters still being fetched.
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        if debounce {
            // Let quick filter taps settle before calling the API (Edamam rate-limits per minute).
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        do {
            var recipes = try await app.services.recipes.search(request, userId: app.user?.uid)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Meat-free filters: also show recipes that usually have meat, cooked with tofu instead.
            if IngredientSwapper.needsAdapting(request.filters.diets) {
                var relaxed = request
                relaxed.filters = IngredientSwapper.relaxed(request.filters)
                // Fewer queries for the extra search: Edamam's free plan allows about ten calls a minute.
                relaxed.queries = Array(request.queries.prefix(2))
                if let candidates = try? await app.services.recipes.search(relaxed, userId: app.user?.uid) {
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    recipes = IngredientSwapper.merge(native: recipes, candidates: candidates, diets: request.filters.diets)
                }
            }
            fetched = RecipeScorer.removingNearDuplicates(recipes)
            fetchedFor = request
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if fetchedFor == request && !fetched.isEmpty {
                // A failed refresh of the same results: keep them and say so.
                app.showError(error)
            } else {
                // Don't leave results for a different search on screen.
                fetched = []
                fetchedFor = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Chips

/// A capsule toggle used for filters and ingredient picking.
struct FilterChip: View {
    var title: String
    var systemImage: String?
    var emoji: String?
    var isOn: Bool
    var showsMenu = false
    var dot: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let emoji { Text(emoji).font(.subheadline) }
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title).lineLimit(1)
            if showsMenu { Image(systemName: "chevron.down").imageScale(.small).font(.caption2.weight(.bold)) }
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(isOn ? .semibold : .regular))
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .overlay {
            if !isOn { Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5) }
        }
        .contentShape(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private extension View {
    /// A full-width row that sits on the list background (chip rows, the scope picker).
    func controlRow(horizontal: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 4, leading: horizontal, bottom: 4, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
