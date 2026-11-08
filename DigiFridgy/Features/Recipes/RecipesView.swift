import SwiftUI

/// Recipes ranked by "use expiring food first".
struct RecipesView: View {
    @Environment(AppState.self) private var app
    @State private var results: [ScoredRecipe] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var openURL: IdentifiableURL?

    private var queries: [String] { app.services.scorer.queries(for: app.items) }
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
            .task(id: reloadKey) { await load(force: false) }
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
            }
            Section {
                ForEach(results) { scored in
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
                HStack(spacing: 10) {
                    if let minutes = scored.recipe.totalTimeMinutes {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text("\(Int(minutes)) min")
                        }
                        .fixedSize()
                    }
                    if let source = scored.recipe.sourceName { Text(source) }
                    Spacer()
                    let expiring = scored.uses.filter { $0.daysUntilExpiry <= 3 }.count
                    if expiring > 0 {
                        StatusChip(text: "Uses \(expiring) expiring", tone: .success)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
