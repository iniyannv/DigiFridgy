import Foundation
import os

/// Household data in SpacetimeDB (module: `server/spacetimedb`).
/// Reads come from per-caller views (`my_profile`, `my_household`, `my_items`, `my_shopping`, `my_prices`),
/// so a user only ever sees their own household. Writes go through membership-checked reducers.
/// Live updates: a WebSocket subscription to the views pushes every change as it commits; while it's down,
/// the views are polled every couple of seconds and re-read right after each local write.
final class SpacetimeHouseholdRepository: HouseholdRepository {
    private static let log = Logger(subsystem: "DigiFridgy", category: "repository")
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
    private var live: SpacetimeSubscription?
    private var fallbackTask: Task<Void, Never>?
    private var latestItems: [FridgeItem]?
    private var latestShopping: [ShoppingListItem]?
    /// From `my_profile`; roommates' bank households are matched to app users by it.
    private(set) var identityHex: String?
    /// The published module predates `use_item`: fall back to plain count changes.
    private var useItemMissing = false
    /// Rows whose `data` couldn't be decoded (logged; a non-zero count means a schema mismatch).
    private(set) var droppedRowCount = 0
    /// Latest subscription update per table, so an older off-main decode never overwrites a newer one.
    private var decodeGeneration: [String: Int] = [:]

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
        let hex = row.string("identity_hex")
        if !hex.isEmpty { identityHex = hex }
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
        if identityHex == nil {
            // A new user has no profile row until they create or join a household.
            identityHex = try? await client.query("SELECT * FROM my_profile").first?.string("identity_hex")
        }
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
        decodeItems(try await client.query("SELECT * FROM my_items"))
    }

    private func decodeItems(_ rows: [SpacetimeClient.Row]) -> [FridgeItem] {
        let items = rows.compactMap { row in
            Self.item(id: row.string("id"), count: row.int("count"), data: row.string("data"), decoder: decoder)
        }
        noteDropped(rows.count - items.count, table: "my_items")
        return items
    }

    nonisolated private static func item(id: String, count: Int, data: String, decoder: JSONDecoder) -> FridgeItem? {
        guard var item = try? decoder.decode(FridgeItem.self, from: Data(data.utf8)) else { return nil }
        item.id = id
        item.count = count
        return item
    }

    private func noteDropped(_ count: Int, table: String) {
        guard count > 0 else { return }
        droppedRowCount += count
        Self.log.error("\(count) \(table, privacy: .public) row(s) couldn't be decoded (\(self.droppedRowCount) so far)")
    }

    /// Subscription rows are JSON arrays in the view's column order. Extra (new) columns are ignored;
    /// rows with too few columns are dropped. Runs off the main actor: a full table can be large.
    @concurrent
    nonisolated private static func decodeRows(_ rows: [String], columns: [String], table: String) async
        -> (items: [FridgeItem], shopping: [ShoppingListItem], dropped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var items: [FridgeItem] = []
        var shopping: [ShoppingListItem] = []
        var dropped = 0
        for json in rows {
            guard let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any],
                  values.count >= columns.count else { dropped += 1; continue }
            var row: SpacetimeClient.Row = [:]
            for (name, value) in zip(columns, values) { row[name] = SpacetimeClient.unwrapOption(value) }
            switch table {
            case "my_items":
                if let item = item(id: row.string("id"), count: row.int("count"), data: row.string("data"), decoder: decoder) {
                    items.append(item)
                } else {
                    dropped += 1
                }
            case "my_shopping":
                if var entry = try? decoder.decode(ShoppingListItem.self, from: Data(row.string("data").utf8)) {
                    entry.id = row.string("id")
                    shopping.append(entry)
                } else {
                    dropped += 1
                }
            default:
                break
            }
        }
        shopping.sort { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
        return (items, shopping, dropped)
    }

    func itemsStream(householdId: String) -> AsyncThrowingStream<[FridgeItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[FridgeItem], any Error>.makeStream()
        let token = UUID()
        itemContinuations[token] = continuation
        if let latestItems { continuation.yield(latestItems) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.itemContinuations[token] = nil
                self?.stopLiveIfIdle()
            }
        }
        startLive()
        return stream
    }

    // MARK: Live updates
    //
    // One WebSocket subscription to `my_items` + `my_shopping` feeds every open stream: the server pushes
    // each change (from this phone, another member's phone, or the iMessage backend) as it commits.
    // While the socket is down, the views are polled over HTTP instead, which also surfaces auth errors.

    private func startLive() {
        if live == nil {
            let subscription = SpacetimeSubscription(client: client, queries: [
                .init(table: "my_items", columns: ["id", "count", "data", "updated_at_ms"]),
                .init(table: "my_shopping", columns: ["id", "data"]),
            ])
            subscription.onRawRows = { [weak self] table, columns, rows in
                guard let self else { return }
                let generation = (self.decodeGeneration[table] ?? 0) + 1
                self.decodeGeneration[table] = generation
                Task { [weak self] in
                    let decoded = await Self.decodeRows(rows, columns: columns, table: table)
                    guard let self, self.decodeGeneration[table] == generation else { return }
                    self.noteDropped(decoded.dropped, table: table)
                    switch table {
                    case "my_items": self.publishItems(decoded.items)
                    case "my_shopping": self.publishShopping(decoded.shopping)
                    default: break
                    }
                }
            }
            live = subscription
            subscription.start()
        }
        if fallbackTask == nil {
            fallbackTask = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    var delay = self.pollInterval
                    if self.live?.isConnected != true {
                        do {
                            try await self.pollOnce()
                            if failures > 0 { Self.log.info("polling recovered after \(failures) failure(s)") }
                            failures = 0
                        } catch {
                            if Self.isFatal(error) {
                                // Signed out / token rejected: retrying can't help, so end the streams.
                                self.itemContinuations.values.forEach { $0.finish(throwing: error) }
                                self.shoppingContinuations.values.forEach { $0.finish(throwing: error) }
                                self.itemContinuations = [:]
                                self.shoppingContinuations = [:]
                                self.stopLiveIfIdle()
                                return
                            }
                            // Offline or a server hiccup: keep the streams open and retry with capped backoff.
                            failures += 1
                            Self.log.error("poll failed (\(failures)): \(error.localizedDescription, privacy: .public)")
                            delay = Self.backoff(base: self.pollInterval, failures: failures)
                        }
                    }
                    try? await Task.sleep(for: delay)
                }
            }
        }
    }

    private func stopLiveIfIdle() {
        guard itemContinuations.isEmpty, shoppingContinuations.isEmpty else { return }
        live?.stop()
        live = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        latestItems = nil
        latestShopping = nil
    }

    private func pollOnce() async throws {
        let items = try await fetchItems(householdId: "")
        publishItems(items)
        if !shoppingContinuations.isEmpty, let list = try? await fetchShopping() {
            publishShopping(list)
        }
    }

    private func publishItems(_ items: [FridgeItem]) {
        let sorted = items.sorted { $0.id < $1.id }
        guard sorted != latestItems else { return }
        latestItems = sorted
        itemContinuations.values.forEach { $0.yield(sorted) }
    }

    private func publishShopping(_ list: [ShoppingListItem]) {
        guard list != latestShopping else { return }
        latestShopping = list
        shoppingContinuations.values.forEach { $0.yield(list) }
    }

    /// After a local write: the subscription delivers the change itself; without it, re-read right away.
    private func refreshItems() async {
        guard live?.isConnected != true, !itemContinuations.isEmpty,
              let items = try? await fetchItems(householdId: "") else { return }
        publishItems(items)
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

    func useItem(id: String, qty: Int, name: String, remaining: Int, householdId: String) async throws {
        if !useItemMissing {
            do {
                // Lowers the count (removing the item at zero) and adds a row to the shared "who used what" log.
                try await client.call("use_item", [id, qty, name])
                await refreshItems()
                return
            } catch let error as SpacetimeError where Self.isMissingReducer(error, named: "use_item") {
                useItemMissing = true
            }
        }
        if remaining <= 0 {
            try await deleteItem(id: id, householdId: householdId)
        } else {
            try await incrementCount(itemId: id, by: -qty, householdId: householdId)
        }
    }

    // MARK: Shopping list

    private func fetchShopping() async throws -> [ShoppingListItem] {
        decodeShopping(try await client.query("SELECT * FROM my_shopping"))
    }

    private func decodeShopping(_ rows: [SpacetimeClient.Row]) -> [ShoppingListItem] {
        rows.compactMap { row in
            guard var entry = try? decoder.decode(ShoppingListItem.self, from: Data(row.string("data").utf8)) else { return nil }
            entry.id = row.string("id")
            return entry
        }
        .sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
    }

    func shoppingStream(householdId: String) -> AsyncThrowingStream<[ShoppingListItem], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[ShoppingListItem], any Error>.makeStream()
        let token = UUID()
        shoppingContinuations[token] = continuation
        if let latestShopping { continuation.yield(latestShopping) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.shoppingContinuations[token] = nil
                self?.stopLiveIfIdle()
            }
        }
        startLive()
        return stream
    }

    private func refreshShopping() async {
        guard live?.isConnected != true, !shoppingContinuations.isEmpty, let list = try? await fetchShopping() else { return }
        publishShopping(list)
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

    /// Poll delay after `failures` consecutive failures: doubles from `base`, capped at 30 s.
    nonisolated static func backoff(base: Duration, failures: Int) -> Duration {
        min(base * (1 << min(failures, 5)), .seconds(30))
    }

    /// The module doesn't have this reducer (older publish), whatever HTTP status it came with.
    nonisolated static func isMissingReducer(_ error: SpacetimeError, named reducer: String) -> Bool {
        let text: String
        switch error {
        case .server(_, let body), .reducer(let body), .badResponse(let body): text = body.lowercased()
        default: return false
        }
        // Not plain "not found": the reducer itself says that about a missing item.
        let generic = ["no such reducer", "reducer not found", "unknown reducer"]
        return generic.contains { text.contains($0) }
            || (text.contains(reducer.lowercased()) && text.contains("does not exist"))
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
        do {
            try Keychain.set(token, for: Self.tokenKey)
            try Keychain.set(identity, for: Self.identityKey)
        } catch {
            // Half-saved credentials would lose the identity on the next launch: save both or neither.
            Keychain.delete(Self.tokenKey)
            Keychain.delete(Self.identityKey)
            throw error
        }
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
