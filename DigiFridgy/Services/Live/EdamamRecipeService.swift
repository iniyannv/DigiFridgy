import Foundation

/// Edamam Recipe Search API v2 with an on-disk cache (the free tier is rate limited).
final class EdamamRecipeService: RecipeService {
    private let api: APIClient
    private let cache = RecipeCache()

    init(api: APIClient = .shared) {
        self.api = api
    }

    func search(queries: [String], healthLabels: [String], userId: String?) async throws -> [Recipe] {
        guard Secrets.hasEdamam else { throw APIError.notConfigured("Edamam") }
        let cacheKey = (queries + healthLabels).joined(separator: "|")
        if let cached = cache.load(key: cacheKey, maxAge: 6 * 3600) { return cached }

        var results: [Recipe] = []
        var seen = Set<String>()
        var lastError: (any Error)?
        for query in queries where results.count < 20 {
            do {
                for recipe in try await fetch(query: query, healthLabels: healthLabels, userId: userId)
                where seen.insert(recipe.id).inserted {
                    results.append(recipe)
                }
            } catch {
                lastError = error
            }
        }
        if results.isEmpty, let lastError {
            // Serve stale cache rather than nothing.
            if let stale = cache.load(key: cacheKey, maxAge: .infinity) { return stale }
            throw lastError
        }
        cache.save(results, key: cacheKey)
        return results
    }

    private func fetch(query: String, healthLabels: [String], userId: String?) async throws -> [Recipe] {
        var params: [(String, String)] = [
            ("type", "public"), ("q", query),
            ("app_id", Secrets.edamamAppID), ("app_key", Secrets.edamamAppKey),
        ]
        params += healthLabels.map { ("health", $0) }
        params += ["uri", "label", "image", "url", "source", "ingredients", "calories", "yield", "totalTime"]
            .map { ("field", $0) }
        var headers: [String: String] = [:]
        // Required by Edamam accounts with active-user tracking; harmless otherwise.
        if let userId { headers["Edamam-Account-User"] = String(userId.prefix(30)) }
        let response = try await api.get(EdamamResponse.self,
                                          from: api.url("https://api.edamam.com/api/recipes/v2", query: params),
                                          headers: headers)
        return response.hits.map { $0.recipe.toRecipe() }
    }
}

nonisolated struct EdamamResponse: Decodable, Sendable {
    var hits: [Hit]

    struct Hit: Decodable, Sendable { var recipe: DTO }

    struct DTO: Decodable, Sendable {
        var uri: String
        var label: String
        var image: String?
        var url: String
        var source: String?
        var ingredients: [Ingredient]?
        var calories: Double?
        var yield: Double?
        var totalTime: Double?

        struct Ingredient: Decodable, Sendable {
            var text: String?
            var food: String?
        }

        func toRecipe() -> Recipe {
            Recipe(
                id: uri.components(separatedBy: "#recipe_").last ?? uri,
                title: label,
                imageURL: image,
                sourceURL: url,
                sourceName: source,
                ingredients: (ingredients ?? []).map {
                    RecipeIngredient(text: $0.text ?? $0.food ?? "", food: ($0.food ?? $0.text ?? "").lowercased())
                },
                calories: calories,
                servings: yield,
                totalTimeMinutes: (totalTime ?? 0) > 0 ? totalTime : nil
            )
        }
    }
}

/// JSON file cache in Caches/ keyed by query string.
nonisolated final class RecipeCache: Sendable {
    private struct Entry: Codable { var savedAt: Date; var recipes: [Recipe] }

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recipes", isDirectory: true)
    }

    private func file(for key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(String(safe.prefix(120)) + ".json")
    }

    func load(key: String, maxAge: TimeInterval) -> [Recipe]? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date.now.timeIntervalSince(entry.savedAt) < maxAge else { return nil }
        return entry.recipes
    }

    /// Most recent cache entry regardless of key (offline fallback).
    func loadLatest() -> [Recipe]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let data = try? Data(contentsOf: newest),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry.recipes
    }

    func save(_ recipes: [Recipe], key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Entry(savedAt: .now, recipes: recipes)) {
            try? data.write(to: file(for: key))
        }
    }
}
