import Foundation

/// Household data in SpacetimeDB (module: `server/spacetimedb`).
/// Reads come from per-caller views (`my_profile`, `my_household`, `my_items`, `my_shopping`, `my_prices`),
/// so a user only ever sees their own household. Writes go through membership-checked reducers.
/// Live updates: views are polled every couple of seconds while a stream is active, and immediately after
/// every local write.
final class SpacetimeHouseholdRepository: HouseholdRepository {
    private let client: SpacetimeClient
    private let pollInterval: Duration

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    private var itemContinuations: [UUID: AsyncThrowingStream<[FridgeItem], any Error>.Continuation] = [:]
    private var shoppingContinuations: [UUID: AsyncThrowingStream<[ShoppingListItem], any Error>.Continuation] = [:]

    init(client: SpacetimeClient, pollInterval: Duration = .seconds(2)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: Profile

    func profile(uid: String) async throws -> UserProfile? {
        guard let row = try await client.query("SELECT * FROM my_profile").first else { return nil }
        var profile = (try? decoder.decode(UserProfile.self, from: Data(row.string("data").utf8)))
            ?? UserProfile(uid: uid)
        profile.uid = uid
        let hid = row.string("household_id")
        profile.householdId = hid.isEmpty ? nil : hid
        return profile
    }

    func saveProfile(_ profile: UserProfile) async throws {
        // household_id is owned by the server (create/join/leave reducers); only settings are saved here.
        try await client.call("save_profile", [json(profile)])
    }

    // MARK: Household

    private func currentHousehold() async throws -> Household? {
        guard let row = try await client.query("SELECT * FROM my_household").first else { return nil }
        return Household(id: row.string("id"), name: row.string("name"), inviteCode: row.string("invite_code"),
                         memberUids: row.strings("members"), createdAt: row.date("created_at_ms"))
    }

    func createHousehold(name: String, ownerUid: String) async throws -> Household {
        let id = UUID().uuidString
        try await client.call("create_household", [id, name])
        guard let household = try await currentHousehold() else {
            throw SpacetimeError.badResponse("household not visible after create")
        }
        return household
    }

    func joinHousehold(code: String, uid: String) async throws -> Household {
        try await client.call("join_household", [code.uppercased().trimmingCharacters(in: .whitespaces)])
        guard let household = try await currentHousehold() else { throw HouseholdError.codeNotFound }
        return household
    }

    func household(id: String) async throws -> Household? {
        let household = try await currentHousehold()
        return household?.id == id ? household : nil
    }

    func leaveHousehold(id: String, uid: String) async throws {
        try await client.call("leave_household", [])
    }

    // MARK: Items

    func fetchItems(householdId: String) async throws -> [FridgeItem] {
        try await client.query("SELECT * FROM my_items").compactMap { row in
            guard var item = try? decoder.decode(FridgeItem.self, from: Data(row.string("data").utf8)) else { return nil }
            item.id = row.string("id")
            item.count = row.int("count")
            return item
        }
    }

    func itemsStream(householdId: String) -> AsyncThrowingStream<[FridgeItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[FridgeItem], any Error>.makeStream()
        let token = UUID()
        itemContinuations[token] = continuation
        let task = Task { [weak self] in
            var last: [FridgeItem]?
            var failures = 0
            while !Task.isCancelled, let self {
                do {
                    let items = try await self.fetchItems(householdId: householdId).sorted { $0.id < $1.id }
                    failures = 0
                    if items != last {
                        last = items
                        continuation.yield(items)
                    }
                } catch {
                    failures += 1
                    // Transient network blips are fine; surface persistent failures (e.g. auth) once.
                    if failures == 3 || Self.isFatal(error) {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { @MainActor in self?.itemContinuations[token] = nil }
        }
        return stream
    }

    /// Pushes fresh data to open streams right after a local write.
    private func refreshItems() async {
        guard !itemContinuations.isEmpty, let items = try? await fetchItems(householdId: "") else { return }
        itemContinuations.values.forEach { $0.yield(items) }
    }

    func saveItem(_ item: FridgeItem, householdId: String) async throws {
        try await client.call("upsert_item", [item.id, item.count, json(item)])
        await refreshItems()
    }

    func saveItems(_ items: [FridgeItem], householdId: String) async throws {
        try await client.call("upsert_items", [items.map(\.id), items.map(\.count), try items.map(json)])
        await refreshItems()
    }

    func incrementCount(itemId: String, by delta: Int, householdId: String) async throws {
        try await client.call("increment_count", [itemId, delta])
        await refreshItems()
    }

    func deleteItem(id: String, householdId: String) async throws {
        try await client.call("delete_item", [id])
        await refreshItems()
    }

    // MARK: Shopping list

    private func fetchShopping() async throws -> [ShoppingListItem] {
        try await client.query("SELECT * FROM my_shopping").compactMap { row in
            guard var entry = try? decoder.decode(ShoppingListItem.self, from: Data(row.string("data").utf8)) else { return nil }
            entry.id = row.string("id")
            return entry
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    func shoppingStream(householdId: String) -> AsyncThrowingStream<[ShoppingListItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[ShoppingListItem], any Error>.makeStream()
        let token = UUID()
        shoppingContinuations[token] = continuation
        let task = Task { [weak self] in
            var last: [ShoppingListItem]?
            while !Task.isCancelled, let self {
                if let list = try? await self.fetchShopping(), list != last {
                    last = list
                    continuation.yield(list)
                }
                try? await Task.sleep(for: self.pollInterval * 2)
            }
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { @MainActor in self?.shoppingContinuations[token] = nil }
        }
        return stream
    }

    private func refreshShopping() async {
        guard !shoppingContinuations.isEmpty, let list = try? await fetchShopping() else { return }
        shoppingContinuations.values.forEach { $0.yield(list) }
    }

    func saveShoppingItem(_ item: ShoppingListItem, householdId: String) async throws {
        try await client.call("save_shopping_item", [item.id, json(item)])
        await refreshShopping()
    }

    func deleteShoppingItem(id: String, householdId: String) async throws {
        try await client.call("delete_shopping_item", [id])
        await refreshShopping()
    }

    // MARK: Price history

    func priceHistory(upc: String, householdId: String) async throws -> PriceHistory? {
        try await client.query("SELECT * FROM my_prices")
            .first { $0.string("upc") == upc }
            .map { PriceHistory(upc: upc, lastPrice: $0.double("last_price"), lastStoreId: $0.string("last_store_id"),
                                checkedAt: $0.date("checked_at_ms")) }
    }

    func savePriceHistory(_ history: PriceHistory, householdId: String) async throws {
        try await client.call("save_price", [history.upc, history.lastPrice, history.lastStoreId])
    }

    private static func isFatal(_ error: any Error) -> Bool {
        switch error as? SpacetimeError {
        case .unauthorized, .notSignedIn, .notConfigured: true
        default: false
        }
    }
}

/// Sign-in with a SpacetimeDB-issued identity, used when Firebase isn't configured.
/// The token is kept in the Keychain; there is no email/password option in this mode.
final class SpacetimeAuthService: AuthService {
    private static let tokenKey = "spacetime.token"
    private static let identityKey = "spacetime.identity"
    private let client: SpacetimeClient

    init(client: SpacetimeClient) {
        self.client = client
    }

    var supportsEmail: Bool { false }

    var currentUser: AuthUser? {
        guard Keychain.get(Self.tokenKey) != nil, let identity = Keychain.get(Self.identityKey) else { return nil }
        return AuthUser(uid: identity, email: nil, isAnonymous: true)
    }

    func idToken() async throws -> String? { Keychain.get(Self.tokenKey) }

    func signInAnonymously() async throws -> AuthUser {
        let (identity, token) = try await client.createIdentity()
        Keychain.set(token, for: Self.tokenKey)
        Keychain.set(identity, for: Self.identityKey)
        return AuthUser(uid: identity, email: nil, isAnonymous: true)
    }

    func signIn(email: String, password: String) async throws -> AuthUser { throw AuthServiceError.emailUnavailable }
    func signUp(email: String, password: String) async throws -> AuthUser { throw AuthServiceError.emailUnavailable }
    func linkEmail(email: String, password: String) async throws -> AuthUser { throw AuthServiceError.emailUnavailable }

    func signOut() throws {
        Keychain.delete(Self.tokenKey)
        Keychain.delete(Self.identityKey)
    }
}
