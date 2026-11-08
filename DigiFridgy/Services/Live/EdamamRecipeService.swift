import Foundation

/// Edamam Recipe Search API v2 with an on-disk cache (the free tier is rate limited).
final class EdamamRecipeService: RecipeService {
    private let api: APIClient
    private let cache = RecipeCache()

    init(api: APIClient = .shared) {
        self.api = api
    }

    /// Results per query when several run together, so the combined query can't crowd out the rest.
    private static let perQueryLimit = 12
    private static let totalLimit = 40
    /// Edamam image links are signed for an hour; cached results older than that show broken images.
    private static let freshness: TimeInterval = 50 * 60

    func search(_ request: RecipeSearchRequest, userId: String?) async throws -> [Recipe] {
        guard Secrets.hasEdamam else { throw APIError.notConfigured("Edamam") }
        let queries = Array(request.queries.prefix(3))
        guard !queries.isEmpty else { return [] }
        let limit = queries.count > 1 ? Self.perQueryLimit : Self.totalLimit

        // Sequential, most useful query first: the free plan allows about ten calls a minute, so stop at the
        // first rate-limit and show what already came back rather than spending more calls.
        var lists: [[Recipe]] = []
        var firstError: (any Error)?
        var rateLimited = false
        for query in queries {
            if rateLimited {
                // Out of calls for this minute: still use anything already cached.
                if let cached = cache.load(key: Self.cacheKey(query: query, request: request), maxAge: Self.freshness) {
                    lists.append(Array(cached.prefix(limit)))
                }
                continue
            }
            do {
                lists.append(Array(try await cachedFetch(query: query, request: request, userId: userId).prefix(limit)))
            } catch {
                firstError = firstError ?? error
                if case APIError.badStatus(429, _) = error { rateLimited = true }
            }
        }
        if lists.isEmpty, let firstError { throw firstError }

        // Round-robin: the first hit of every query, then the second of every query, and so on.
        var results: [Recipe] = []
        var seen = Set<String>()
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count && seen.insert(list[rank].id).inserted {
                results.append(list[rank])
            }
        }
        return Array(results.prefix(Self.totalLimit))
    }

    /// One query, served from a fresh cache entry when there is one. On failure a stale entry is better than nothing.
    private func cachedFetch(query: String, request: RecipeSearchRequest, userId: String?) async throws -> [Recipe] {
        let params = Self.filterParams(for: request)
        let cacheKey = Self.cacheKey(query: query, request: request)
        if let cached = cache.load(key: cacheKey, maxAge: Self.freshness) { return cached }
        do {
            let recipes = try await fetch(query: query, filterParams: params, userId: userId)
            cache.save(recipes, key: cacheKey)
            return recipes
        } catch {
            if let stale = cache.load(key: cacheKey, maxAge: .infinity) { return stale }
            throw error
        }
    }

    static func cacheKey(query: String, request: RecipeSearchRequest) -> String {
        ([query] + filterParams(for: request).map { "\($0.0)=\($0.1)" }).joined(separator: "|")
    }

    /// Edamam filter parameters: allergen exclusions, diets, meal / dish / cuisine and a time range.
    static func filterParams(for request: RecipeSearchRequest) -> [(String, String)] {
        let filters = request.filters
        var params: [(String, String)] = request.allergenLabels.sorted().map { ("health", $0) }
        params += filters.diets.sorted { $0.rawValue < $1.rawValue }.map { ($0.edamamParam.name, $0.edamamParam.value) }
        if let meal = filters.meal { params.append(("mealType", meal.edamamValue)) }
        if let dish = filters.dish { params.append(("dishType", dish.edamamValue)) }
        if let cuisine = filters.cuisine { params.append(("cuisineType", cuisine.edamamValue)) }
        if let minutes = filters.maxMinutes { params.append(("time", "1-\(minutes)")) }
        return params
    }

    private func fetch(query: String, filterParams: [(String, String)], userId: String?) async throws -> [Recipe] {
        var params: [(String, String)] = [
            ("type", "public"), ("q", query),
            ("app_id", Secrets.edamamAppID), ("app_key", Secrets.edamamAppKey),
        ]
        params += filterParams
        params += ["uri", "label", "image", "images", "url", "source", "ingredients", "calories", "yield", "totalTime",
                   "mealType", "dishType", "cuisineType", "healthLabels", "dietLabels"]
            .map { ("field", $0) }
        let url = api.url("https://api.edamam.com/api/recipes/v2", query: params)
        // Plans without active-user tracking reject the Edamam-Account-User header (401), so send it
        // only when Edamam says the plan requires it.
        do {
            return try await api.get(EdamamResponse.self, from: url).hits.map { $0.recipe.toRecipe() }
        } catch APIError.badStatus(401, let body) where Self.requiresUserHeader(body) {
            guard let userId else { throw APIError.badStatus(401, body) }
            let headers = ["Edamam-Account-User": String(userId.prefix(30))]
            return try await api.get(EdamamResponse.self, from: url, headers: headers).hits.map { $0.recipe.toRecipe() }
        }
    }

    /// True for the 401 Edamam sends when an active-user plan is called without the user header.
    static func requiresUserHeader(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("edamam-account-user") && !text.contains("does not support users")
            && !text.contains("do not supply")
    }
}

nonisolated struct EdamamResponse: Decodable, Sendable {
    var hits: [Hit]

    struct Hit: Decodable, Sendable { var recipe: DTO }

    struct DTO: Decodable, Sendable {
        var uri: String
        var label: String
        var image: String?
        var images: Images?
        var url: String
        var source: String?
        var ingredients: [Ingredient]?
        var calories: Double?
        var yield: Double?
        var totalTime: Double?
        var mealType: [String]?
        var dishType: [String]?
        var cuisineType: [String]?
        var healthLabels: [String]?
        var dietLabels: [String]?

        struct Images: Decodable, Sendable {
            struct Image: Decodable, Sendable { var url: String }
            var LARGE: Image?
            var REGULAR: Image?
        }

        struct Ingredient: Decodable, Sendable {
            var text: String?
            var food: String?
        }

        func toRecipe() -> Recipe {
            Recipe(
                id: uri.components(separatedBy: "#recipe_").last ?? uri,
                title: label,
                imageURL: image,
                largeImageURL: images?.LARGE?.url,
                sourceURL: url,
                sourceName: source,
                ingredients: (ingredients ?? []).map {
                    RecipeIngredient(text: $0.text ?? $0.food ?? "", food: ($0.food ?? $0.text ?? "").lowercased())
                },
                calories: calories,
                servings: yield,
                totalTimeMinutes: (totalTime ?? 0) > 0 ? totalTime : nil,
                mealTypes: mealType,
                dishTypes: dishType,
                cuisineTypes: cuisineType,
                healthLabels: healthLabels,
                dietLabels: dietLabels
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
