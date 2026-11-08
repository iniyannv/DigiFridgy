import Foundation
import CoreGraphics

// Offline implementations used by `--mock`, the Settings toggle, previews,
// and automatically when Firebase / API keys are not configured.

final class MockAuthService: AuthService {
    private let key = "mock.authUser"

    var supportsEmail: Bool { true }
    func idToken() async throws -> String? { nil }

    var currentUser: AuthUser? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key), let uid = dict["uid"] as? String else { return nil }
        return AuthUser(uid: uid, email: dict["email"] as? String, isAnonymous: dict["anon"] as? Bool ?? true)
    }

    private func store(_ user: AuthUser) -> AuthUser {
        var dict: [String: Any] = ["uid": user.uid, "anon": user.isAnonymous]
        if let email = user.email { dict["email"] = email }
        UserDefaults.standard.set(dict, forKey: key)
        return user
    }

    func signInAnonymously() async throws -> AuthUser {
        store(AuthUser(uid: "mock-" + UUID().uuidString.prefix(8), email: nil, isAnonymous: true))
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        guard email.contains("@"), password.count >= 6 else { throw AuthServiceError.invalidCredentials }
        return store(AuthUser(uid: "mock-" + String(MockPriceService.fnv1a(email.lowercased()) % 1_000_000), email: email, isAnonymous: false))
    }

    func signUp(email: String, password: String) async throws -> AuthUser {
        try await signIn(email: email, password: password)
    }

    func linkEmail(email: String, password: String) async throws -> AuthUser {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }
        guard email.contains("@"), password.count >= 6 else { throw AuthServiceError.invalidCredentials }
        return store(AuthUser(uid: user.uid, email: email, isAnonymous: false))
    }

    func signOut() throws {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// In-memory household store persisted to a JSON file so a demo survives relaunches.
final class MockHouseholdRepository: HouseholdRepository {
    private struct Snapshot: Codable {
        var profiles: [String: UserProfile] = [:]
        var households: [String: Household] = [:]
        var items: [String: [String: FridgeItem]] = [:]
        var shopping: [String: [String: ShoppingListItem]] = [:]
        var prices: [String: [String: PriceHistory]] = [:]
    }

    private var data = Snapshot()
    private var itemContinuations: [String: [UUID: AsyncThrowingStream<[FridgeItem], any Error>.Continuation]] = [:]
    private var shoppingContinuations: [String: [UUID: AsyncThrowingStream<[ShoppingListItem], any Error>.Continuation]] = [:]
    private let fileURL: URL

    init(persist: Bool = true) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("mock-store.json")
        if persist, let raw = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Snapshot.self, from: raw) {
            data = decoded
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: fileURL) }
    }

    private func publishItems(_ hid: String) {
        let items = Array(data.items[hid, default: [:]].values)
        itemContinuations[hid]?.values.forEach { $0.yield(items) }
        save()
    }

    private func publishShopping(_ hid: String) {
        let list = data.shopping[hid, default: [:]].values.sorted { $0.addedAt > $1.addedAt }
        shoppingContinuations[hid]?.values.forEach { $0.yield(list) }
        save()
    }

    func profile(uid: String) async throws -> UserProfile? { data.profiles[uid] }

    func saveProfile(_ profile: UserProfile) async throws {
        data.profiles[profile.uid] = profile
        save()
    }

    func createHousehold(name: String, ownerUid: String) async throws -> Household {
        let household = Household(id: UUID().uuidString, name: name, inviteCode: Household.makeInviteCode(),
                                  memberUids: [ownerUid], createdAt: .now)
        data.households[household.id] = household
        save()
        return household
    }

    func joinHousehold(code: String, uid: String) async throws -> Household {
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        guard var household = data.households.values.first(where: { $0.inviteCode == normalized }) else {
            throw HouseholdError.codeNotFound
        }
        if !household.memberUids.contains(uid) { household.memberUids.append(uid) }
        data.households[household.id] = household
        save()
        return household
    }

    func household(id: String) async throws -> Household? { data.households[id] }

    func leaveHousehold(id: String, uid: String) async throws {
        data.households[id]?.memberUids.removeAll { $0 == uid }
        save()
    }

    func itemsStream(householdId: String) -> AsyncThrowingStream<[FridgeItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[FridgeItem], any Error>.makeStream()
        let token = UUID()
        itemContinuations[householdId, default: [:]][token] = continuation
        continuation.yield(Array(data.items[householdId, default: [:]].values))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.itemContinuations[householdId]?[token] = nil }
        }
        return stream
    }

    func fetchItems(householdId: String) async throws -> [FridgeItem] {
        Array(data.items[householdId, default: [:]].values)
    }

    func saveItem(_ item: FridgeItem, householdId: String) async throws {
        data.items[householdId, default: [:]][item.id] = item
        publishItems(householdId)
    }

    func saveItems(_ items: [FridgeItem], householdId: String) async throws {
        for item in items { data.items[householdId, default: [:]][item.id] = item }
        publishItems(householdId)
    }

    func incrementCount(itemId: String, by delta: Int, householdId: String) async throws {
        data.items[householdId]?[itemId]?.count += delta
        publishItems(householdId)
    }

    func deleteItem(id: String, householdId: String) async throws {
        data.items[householdId]?[id] = nil
        publishItems(householdId)
    }

    func shoppingStream(householdId: String) -> AsyncThrowingStream<[ShoppingListItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[ShoppingListItem], any Error>.makeStream()
        let token = UUID()
        shoppingContinuations[householdId, default: [:]][token] = continuation
        continuation.yield(data.shopping[householdId, default: [:]].values.sorted { $0.addedAt > $1.addedAt })
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.shoppingContinuations[householdId]?[token] = nil }
        }
        return stream
    }

    func saveShoppingItem(_ item: ShoppingListItem, householdId: String) async throws {
        data.shopping[householdId, default: [:]][item.id] = item
        publishShopping(householdId)
    }

    func deleteShoppingItem(id: String, householdId: String) async throws {
        data.shopping[householdId]?[id] = nil
        publishShopping(householdId)
    }

    func priceHistory(upc: String, householdId: String) async throws -> PriceHistory? {
        data.prices[householdId]?[upc]
    }

    func savePriceHistory(_ history: PriceHistory, householdId: String) async throws {
        data.prices[householdId, default: [:]][history.upc] = history
        save()
    }
}

final class MockProductLookupService: ProductLookupService {
    func lookup(barcode: String) async throws -> ProductInfo? {
        try? await Task.sleep(for: .milliseconds(300))
        let code = Barcode.normalize(barcode)
        return DemoData.products[code] ?? BarcodeDemoData.products[code]
    }

    func nutrition(forName name: String) async throws -> Nutrition? {
        DemoData.typicalNutrition(forCategory: ShelfLifeService.shared.categoryID(forName: name))
    }
}

final class MockRecipeService: RecipeService {
    func search(_ request: RecipeSearchRequest, userId: String?) async throws -> [Recipe] {
        try? await Task.sleep(for: .milliseconds(400))
        let excluded = Set(request.allergenLabels)
        let words = Set(request.queries.flatMap { ShelfLifeService.tokenize($0) }.filter { $0.count >= 3 })
        return DemoData.recipes.filter { recipe in
            // Crude allergen filtering so the mock behaves like Edamam's health filters.
            let foods = recipe.ingredients.map(\.food).joined(separator: " ")
            if excluded.contains("dairy-free"), foods.contains(anyOf: ["milk", "cheese", "yogurt", "butter", "cream", "parmesan"]) { return false }
            if excluded.contains("egg-free"), foods.contains("egg") { return false }
            if excluded.contains("gluten-free"), foods.contains(anyOf: ["tortilla", "bread", "pasta", "flour", "noodle"]) { return false }
            if excluded.contains("peanut-free"), foods.contains("peanut") { return false }
            if excluded.contains("sesame-free"), foods.contains(anyOf: ["tahini", "sesame", "hummus"]) { return false }
            guard request.filters.admits(recipe) else { return false }
            // Like a keyword search: some query word appears in the title or an ingredient.
            let text = ShelfLifeService.tokenize(recipe.title + " " + foods).map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
            return words.isEmpty || words.contains { word in
                let stem = word.hasSuffix("s") ? String(word.dropLast()) : word
                return text.contains(stem)
            }
        }
    }
}

final class MockRecallService: RecallService {
    func recentRecalls(days: Int) async throws -> [Recall] { [] }
}

final class MockKrogerService: KrogerService {
    var isLive: Bool { false }

    func locations(near: Coordinate, radiusMiles: Double, limit: Int) async throws -> [Store] {
        let offsets: [(Double, Double, String)] = [(0.018, -0.012, "Kroger Marketplace"), (-0.03, 0.025, "Kroger"),
                                                   (0.05, 0.04, "Kroger")]
        return offsets.enumerated().compactMap { idx, o in
            let coord = Coordinate(latitude: near.latitude + o.0, longitude: near.longitude + o.1)
            let distance = near.distanceMiles(to: coord)
            guard distance <= radiusMiles else { return nil }
            return Store(id: "kroger-mock-\(idx)", chain: "Kroger", name: o.2, address: "Sample location",
                         coordinate: coord, distanceMiles: distance, isKroger: true)
        }
    }

    func price(upc: String?, term: String, locationId: String) async throws -> KrogerPrice? { nil }
}

final class MockWalmartService: WalmartService {
    var isLive: Bool { false }
    func price(upc: String?, term: String) async throws -> KrogerPrice? { nil }
}

final class MockStoreSearchService: StoreSearchService {
    func stores(near: Coordinate, radiusMiles: Double, chains: [OtherChain]) async -> [Store] {
        chains.enumerated().compactMap { idx, chain in
            let angle = Double(idx) * 1.25
            let dist = 0.02 + Double(idx) * 0.012
            let coord = Coordinate(latitude: near.latitude + dist * cos(angle), longitude: near.longitude + dist * sin(angle))
            let miles = near.distanceMiles(to: coord)
            guard miles <= radiusMiles else { return nil }
            return Store(id: "\(chain.rawValue)-mock", chain: chain.rawValue, name: chain.rawValue,
                         address: "Sample location", coordinate: coord, distanceMiles: miles, isKroger: false)
        }
    }
}

final class MockLocationService: LocationService {
    func currentCoordinate() async -> Coordinate? { .demoFallback }
}

final class MockReceiptTextRecognizer: ReceiptTextRecognizer {
    func recognizeLines(in image: CGImage) async throws -> [String] {
        SampleReceipts.walmart.components(separatedBy: .newlines)
    }
}

final class MockReceiptNormalizer: ReceiptNormalizer {
    var usesOnDeviceModel: Bool { false }
    func normalize(_ lines: [ParsedReceiptLine]) async -> [NormalizedReceiptLine] {
        lines.map { AbbreviationNormalizer().normalize($0, shelfLife: .shared) }
    }
}

final class MockNotificationService: NotificationService {
    private(set) var log: [String] = []
    /// Reminder ids as `reconcile` would leave them.
    private(set) var reminders: [String: ReminderSpec] = [:]
    func requestAuthorization() async -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func reconcile(items: [FridgeItem]) async {
        let (add, remove) = ReminderPlanner.diff(pending: reminders, desired: ReminderPlanner.desired(for: items))
        remove.forEach { reminders[$0] = nil }
        reminders.merge(add) { $1 }
        log.append("reconcile +\(add.count) -\(remove.count)")
    }
    func removeAllReminders() {
        reminders = [:]
        log.append("remove all")
    }
    func notifyNow(id: String, title: String, body: String) { log.append("notify \(title)") }
}

extension String {
    nonisolated func contains(anyOf needles: [String]) -> Bool {
        needles.contains { self.contains($0) }
    }
}
