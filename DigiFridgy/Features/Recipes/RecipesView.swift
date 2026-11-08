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
                    ContentUnavailableView("No ingredients yet", systemImage: "fork.knife",
                                           description: Text("Add food to your fridge and recipes that use it up will show here."))
                } else if isLoading && results.isEmpty {
                    skeleton
                } else if let errorMessage, results.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load recipes", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load(force: true) } }
                    }
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
                        Text("Filtered: \(healthLabels.joined(separator: ", "))")
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
                }
            } footer: {
                Text(app.services.isMock || !Secrets.hasEdamam ? "Sample recipes (offline mode)." : "Recipes from Edamam.")
            }
        }
        .refreshable { await load(force: true) }
    }

    private var soonestSummary: String {
        app.sortedItems.filter { $0.daysUntilExpiry() >= 0 }.prefix(4).map {
            "\($0.name) (\(ExpiryLabel.relative($0.daysUntilExpiry())))"
        }.joined(separator: ", ")
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
                        Color.secondary.opacity(0.15)
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
            .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(scored.recipe.title).font(.headline).lineLimit(2)
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
                    Text("Score \(scored.score)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(scored.score > 0 ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12), in: .capsule)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// "Uses: spinach (exp. 1d), chicken" — expiring-soon matches in orange.
    private var usesText: Text {
        var parts: [Text] = []
        for match in scored.uses {
            if match.daysUntilExpiry <= 3 {
                parts.append(Text("\(match.itemName) (exp. \(max(match.daysUntilExpiry, 0))d)").foregroundStyle(.orange).bold())
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
