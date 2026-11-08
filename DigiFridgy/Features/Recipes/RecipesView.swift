import SwiftUI

/// Recipes ranked by "use expiring food first". Tapping expiring items under "Must include" shows only
/// recipes that use all of them (the same idea as texting "what can I make with what's expiring?").
struct RecipesView: View {
    @Environment(AppState.self) private var app
    @State private var results: [ScoredRecipe] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var openURL: IdentifiableURL?
    @State private var mustUse: Set<String> = []
    /// "All expiring": recipes that use any expiring item, the ones using the most first.
    @State private var anyExpiring = false
    /// Recipes fetched for the picked items when none of the loaded ones use them all.
    @State private var extra: [ScoredRecipe] = []
    @State private var isSearchingPicked = false
    /// Sort and filters from the toolbar menu. The sort is remembered between launches.
    @AppStorage("recipes.sort") private var savedSort = RecipeSort.bestMatch.rawValue
    @State private var ranking = RecipeRanking()

    /// Items expiring in the next 3 days, one per generic name ("spinach"), soonest first.
    private var expiring: [ExpiringChoice] {
        let scorer = app.services.scorer
        var seen = Set<String>()
        return app.items
            .filter { $0.count > 0 && (0...3).contains($0.daysUntilExpiry()) }
            .sorted { $0.expiresAt < $1.expiresAt }
            .compactMap { item in
                let term = scorer.keyTerm(for: item)
                guard seen.insert(term).inserted else { return nil }
                return ExpiringChoice(term: term, emoji: CategoryStyle.emoji(for: item.category),
                                      days: item.daysUntilExpiry())
            }
    }

    /// The picked items that are still expiring (eaten or tossed ones drop out on their own).
    private var picked: [String] {
        expiring.map(\.term).filter(mustUse.contains)
    }

    private var queries: [String] { app.services.scorer.queries(for: app.items) }

    /// Searches for the picked items ("chicken spinach", then each one).
    private var pickedQueries: [String] {
        let terms = picked
        guard !terms.isEmpty else { return [] }
        var out = [terms.joined(separator: " ")]
        if terms.count > 2 { out.append(terms.prefix(2).joined(separator: " ")) }
        out += terms
        var unique = Set<String>()
        return out.filter { unique.insert($0).inserted }
    }

    /// With items picked, only recipes that use every one of them (from what's loaded, plus any extra search).
    private var shown: [ScoredRecipe] {
        guard anyExpiring else { return matching(picked) }
        let soon = Set(expiring.map(\.term))
        func count(_ r: ScoredRecipe) -> Int { Set(r.uses.map(\.itemName)).intersection(soon).count }
        return results.filter { count($0) > 0 }
            .sorted { (count($0), $0.score) > (count($1), $1.score) }
    }

    private var filterLabel: String {
        anyExpiring ? "what's expiring" : picked.joined(separator: " and ")
    }

    private func matching(_ terms: [String]) -> [ScoredRecipe] {
        let need = Set(terms)
        guard !need.isEmpty else { return results }
        var seen = Set<String>()
        return (results + extra)
            .filter { need.isSubset(of: Set($0.uses.map(\.itemName))) && seen.insert($0.id).inserted }
            .sorted { ($0.score, -$0.missing.count) > ($1.score, -$1.missing.count) }
    }
    private var healthLabels: [String] {
        Allergen.allCases.filter(app.userAllergens.contains).map(\.edamamHealthLabel)
    }
    /// Reload when the soonest-expiring items or allergen filters change.
    private var reloadKey: String { (queries + healthLabels).joined(separator: "|") }

    var body: some View {
        NavigationStack {
            Group {
                if app.items.isEmpty {
                    EmptyStateView(symbol: "fork.knife",
                                   title: "No ingredients yet",
                                   message: "Add food to your fridge and we'll suggest recipes that use what's expiring first.")
                } else if isLoading && results.isEmpty {
                    skeleton
                } else if errorMessage != nil, results.isEmpty {
                    EmptyStateView(symbol: "wifi.exclamationmark",
                                   title: "Couldn't load recipes",
                                   message: "Check your internet connection and try again.",
                                   primaryTitle: "Try again", primary: { Task { await load(force: true) } })
                } else if results.isEmpty && !isLoading {
                    EmptyStateView(symbol: "fork.knife",
                                   title: "No recipe matches",
                                   message: healthLabels.isEmpty
                                       ? "We couldn't find recipes for what's in your fridge. Add a few more ingredients and try again."
                                       : "We couldn't find recipes for what's in your fridge that avoid your allergens. Add a few more ingredients and try again.",
                                   primaryTitle: "Refresh", primary: { Task { await load(force: true) } })
                } else {
                    list
                }
            }
            .navigationTitle("Recipes")
            .toolbar {
                if !app.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { rankingMenu }
                }
            }
            .onAppear { ranking.sort = RecipeSort(rawValue: savedSort) ?? .bestMatch }
            .onChange(of: ranking.sort) { _, new in savedSort = new.rawValue }
            .task(id: reloadKey) { await load(force: false) }
            .task(id: picked) { await loadPicked() }
            .sheet(item: $openURL) { SafariView(url: $0.url).ignoresSafeArea() }
        }
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Using up first", systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline.bold())
                    Text(soonestSummary).font(.subheadline).foregroundStyle(.secondary)
                    if !healthLabels.isEmpty {
                        Text("Avoiding: \(Allergen.allCases.filter(app.userAllergens.contains).map(\.displayName).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !expiring.isEmpty {
                    mustIncludeRow
                }
                if !ranking.isDefault {
                    HStack {
                        Label(ranking.summary, systemImage: "line.3.horizontal.decrease")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { ranking = RecipeRanking() }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if shown.isEmpty {
                Section {
                    if isSearchingPicked {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Finding recipes with \(picked.joined(separator: " and "))…")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(anyExpiring ? "None of these recipes use what's expiring yet."
                                         : "No recipes use all of \(filterLabel) yet.").font(.subheadline.bold())
                            Text("Tap one off to see more.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if !shown.isEmpty && displayed.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No recipes match \(ranking.summary.lowercased()).").font(.subheadline.bold())
                        Text("Loosen a filter to see more.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button("Reset filters") {
                        ranking.difficulty = .any
                        ranking.time = .any
                        ranking.nothingToBuy = false
                    }
                }
            }
            Section {
                ForEach(displayed) { scored in
                    Button {
                        if let url = URL(string: scored.recipe.sourceURL) { openURL = IdentifiableURL(url: url) }
                    } label: {
                        RecipeCard(scored: scored)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the recipe")
                }
            } footer: {
                Text(app.services.isMock || !Secrets.hasEdamam ? "Sample recipes." : "Recipes from Edamam.")
            }
        }
        .refreshable { await load(force: true) }
    }

    /// What the list shows: the must-include result, then the menu's filters and sort.
    private var displayed: [ScoredRecipe] { ranking.apply(shown) }

    private var rankingMenu: some View {
        Menu {
            Picker(selection: $ranking.sort) {
                ForEach(RecipeSort.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            } label: {
                Label("Sort by", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            Section("Filter") {
                Picker(selection: $ranking.difficulty) {
                    ForEach(DifficultyFilter.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Difficulty", systemImage: "chart.bar")
                }
                .pickerStyle(.menu)
                Picker(selection: $ranking.time) {
                    ForEach(TimeLimit.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Time", systemImage: "clock")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $ranking.nothingToBuy) {
                    Label("Nothing to buy", systemImage: "cart.badge.checkmark")
                }
            }
            if !ranking.isDefault {
                Button("Reset", systemImage: "arrow.counterclockwise") { ranking = RecipeRanking() }
            }
        } label: {
            Label("Sort and filter", systemImage: ranking.isDefault
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityValue(ranking.isDefault ? "Best match" : ranking.summary)
    }

    /// "Must include": tap expiring items to only see recipes that use them.
    private var mustIncludeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Must include").font(.subheadline.bold())
                Spacer()
                if anyExpiring || !picked.isEmpty {
                    Button("Clear") { mustUse.removeAll(); anyExpiring = false }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        anyExpiring.toggle()
                        mustUse.removeAll()
                    } label: {
                        chipLabel("All expiring", emoji: "⏰", on: anyExpiring)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows recipes that use what's expiring, the ones using the most first")
                    .accessibilityAddTraits(anyExpiring ? .isSelected : [])
                    ForEach(expiring) { choice in
                        Button {
                            anyExpiring = false
                            if mustUse.contains(choice.term) { mustUse.remove(choice.term) } else { mustUse.insert(choice.term) }
                        } label: {
                            chipLabel("\(choice.term) · \(choice.dayText)", emoji: choice.emoji,
                                      on: mustUse.contains(choice.term))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(choice.term), expires \(choice.dayText)")
                        .accessibilityAddTraits(mustUse.contains(choice.term) ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .sensoryFeedback(.selection, trigger: mustUse)
        .sensoryFeedback(.selection, trigger: anyExpiring)
    }

    private func chipLabel(_ text: String, emoji: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Text(emoji)
            Text(text).lineLimit(1)
            if on { Image(systemName: "checkmark").imageScale(.small) }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(on ? Tone.warning.fill : Tone.neutral.fill, in: .capsule)
        .overlay(Capsule().strokeBorder(on ? Tone.warning.color : .clear, lineWidth: 1))
        .foregroundStyle(on ? AnyShapeStyle(Tone.warning.color) : AnyShapeStyle(.primary))
        .contentShape(.capsule)
    }

    private var soonestSummary: String {
        app.sortedItems.filter { $0.daysUntilExpiry() >= 0 }.prefix(4).map { item in
            let days = item.daysUntilExpiry()
            let about = item.expiryIsEstimated ? "about " : ""
            let when = days == 0 ? "\(about)today" : days == 1 ? "\(about)tomorrow" : "in \(about)\(days) days"
            return "\(item.name), \(when)"
        }.joined(separator: " · ")
    }

    private var skeleton: some View {
        List {
            ForEach(0..<4, id: \.self) { _ in
                RecipeCard(scored: ScoredRecipe(
                    recipe: Recipe(id: UUID().uuidString, title: "Loading a tasty recipe", imageURL: nil, sourceURL: "",
                                   sourceName: "Source", ingredients: []),
                    score: 0, uses: [RecipeMatch(itemName: "something", daysUntilExpiry: 1)], missing: ["a", "b"]))
            }
        }
        .redacted(reason: .placeholder)
    }

    /// Picking items filters what's already loaded (no network). Only when none of those use them all does
    /// it search once for the picked items; a failure just leaves the "no recipes" row (no error toast).
    private func loadPicked() async {
        let terms = picked
        guard !terms.isEmpty, matching(terms).isEmpty else { return }
        isSearchingPicked = true
        defer { isSearchingPicked = false }
        do {
            let recipes = try await app.services.recipes.search(queries: pickedQueries, healthLabels: healthLabels,
                                                                userId: app.user?.uid)
            let ranked = app.services.scorer.rank(recipes, items: app.items)
            let known = Set((results + extra).map(\.id))
            extra += ranked.filter { !known.contains($0.id) }
        } catch {
            // Rate limits are common on the free recipe API; the row already says nothing matched.
        }
    }

    private func load(force: Bool) async {
        let queries = self.queries
        guard !queries.isEmpty else { results = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let recipes = try await app.services.recipes.search(queries: queries, healthLabels: healthLabels,
                                                                userId: app.user?.uid)
            results = app.services.scorer.rank(recipes, items: app.items)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if !results.isEmpty { app.showError(error) }
        }
    }
}

/// One item under "Must include".
struct ExpiringChoice: Identifiable, Hashable {
    var term: String
    var emoji: String
    var days: Int
    var id: String { term }
    var dayText: String { days == 0 ? "today" : days == 1 ? "tomorrow" : "\(days)d" }
}

struct RecipeCard: View {
    var scored: ScoredRecipe

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let url = scored.recipe.imageURL.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.fill.tertiary)
                    }
                } else {
                    Image(systemName: "fork.knife")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.fill.tertiary)
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(.rect(cornerRadius: Radius.medium))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(Self.displayTitle(scored.recipe.title)).font(.headline).lineLimit(2)
                if !scored.uses.isEmpty {
                    usesText.font(.subheadline)
                }
                if !scored.missing.isEmpty {
                    Text("Missing: \(scored.missing.prefix(4).joined(separator: ", "))\(scored.missing.count > 4 ? "…" : "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    StatusChip(text: scored.recipe.difficulty.label, tone: scored.recipe.difficulty.tone)
                        .fixedSize()
                        .accessibilityLabel("Difficulty: \(scored.recipe.difficulty.label)")
                    if let minutes = scored.recipe.totalTimeMinutes {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text("\(Int(minutes)) min")
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    let expiring = scored.uses.filter { $0.daysUntilExpiry <= 3 }.count
                    if expiring > 0 {
                        StatusChip(text: "Uses \(expiring) expiring", tone: .success)
                            .fixedSize()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let source = scored.recipe.sourceName {
                    Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// Some sources shout ("INSTANT CHOCOLATE MOUSSE"); show those in title case.
    static func displayTitle(_ title: String) -> String {
        // Mostly capitals (a site name tacked on in mixed case still counts).
        let letters = title.filter(\.isLetter)
        let upper = letters.filter(\.isUppercase).count
        guard letters.count >= 4, Double(upper) / Double(letters.count) > 0.7 else { return title }
        return title.localizedCapitalized
    }

    /// "Uses: spinach (exp. 1d), chicken" — expiring-soon matches in orange.
    private var usesText: Text {
        var parts: [Text] = []
        for match in scored.uses {
            if match.daysUntilExpiry <= 3 {
                parts.append(Text("\(match.itemName) (\(match.expiryLabel))").foregroundStyle(Tone.warning.color).bold())
            } else {
                parts.append(Text(match.itemName))
            }
        }
        var result = Text("Uses: ")
        for (index, part) in parts.enumerated() {
            result = Text("\(result)\(index > 0 ? ", " : "")\(part)")
        }
        return result
    }
}
