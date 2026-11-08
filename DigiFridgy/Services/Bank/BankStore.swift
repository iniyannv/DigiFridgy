import Foundation
import Observation

// Talks to the DigiFridgy backend (backend/ folder). The bank is part of the app's household: signing
// up passes the household's invite code, so card purchases stock this same fridge (through SpacetimeDB)
// and every member of the household sees the same budget.

nonisolated struct BankSignupResponse: Decodable, Sendable {
    var household: String
    var household_id: Int
    var handle: String
    var text_this_number: String?
    var line_error: String?
    var simulated: Bool
    var existing: Bool
    var app_linked: Bool?
    var app_link_message: String?
}

nonisolated struct BankHousehold: Decodable, Sendable {
    var id: Int
    var name: String
    var budget: Double
    var members: [String]
    var waste_total: Double
    var week_spend: Double
    var week_waste: Double
    var checking_balance: Double?
    var fund_balance: Double?
    var app_household_id: String?
    var streak: BankStreak?

    var weekLeft: Double { streak?.week_left ?? (budget - week_spend) }
}

/// "Waste less, save more": completed weeks in a row under budget, and what budget sweeps saved.
nonisolated struct BankStreak: Decodable, Sendable, Hashable {
    var weeks: Int
    var saved: Double
    var week_left: Double
    /// This week's waste minus last week's (negative = wasting less).
    var waste_trend: Double
}

/// What happened to one card purchase. The parts add up to what the card was charged.
nonisolated struct PurchaseBreakdown: Decodable, Sendable, Hashable {
    var eaten: Double
    var wasted: Double
    var in_fridge: Double
    var not_added: Double
    var other: Double
    var names: [String: [String]]
}

nonisolated struct SettleDebt: Decodable, Sendable, Identifiable, Hashable {
    var from_id: Int
    var to_id: Int
    var from_name: String
    var to_name: String
    var amount: Double
    var items: [String]
    var id: String { "\(from_id)-\(to_id)" }
    /// The bank moves whole dollars; this is what the confirm dialog shows and what gets quoted to the server.
    var wholeDollars: Int { Int(amount.rounded(.down)) }
}

nonisolated struct SettleRoommate: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
}

nonisolated struct SettleState: Decodable, Sendable {
    var me: Int?
    var app_uses_available: Bool
    var roommates: [SettleRoommate]
    var debts: [SettleDebt]
}

nonisolated struct SettleResult: Decodable, Sendable {
    var ok: Bool?
    var message: String
}

nonisolated struct RoommateResult: Decodable, Sendable {
    var household_id: Int
    var name: String
    var stocked: Int
}

nonisolated struct RoommateUseResult: Decodable, Sendable { var reply: String }

nonisolated struct BankState: Decodable, Sendable {
    var now_local: String
    var offset_days: Double
    var mock_nessie: Bool
    var mock_photon: Bool
    var household: BankHousehold?
    var handle: String?
    var line: String?
}

nonisolated struct CardLine: Decodable, Sendable, Identifiable, Hashable {
    var index: Int
    var sku: String
    var name: String
    var emoji: String
    var qty: Int
    var total: Double
    var shelf_life_days: Int
    var status: String  // pending | stocked | skipped
    var id: Int { index }
    var isAdded: Bool { status == "stocked" }
}

nonisolated struct CardPurchase: Decodable, Sendable, Identifiable {
    var purchase_id: String
    var merchant: String
    var date: String
    var amount: Double
    var lines: [CardLine]
    var breakdown: PurchaseBreakdown?
    var id: String { purchase_id }
    var pendingCount: Int { lines.filter { $0.status != "stocked" }.count }
}

nonisolated struct CardPurchaseList: Decodable, Sendable { var purchases: [CardPurchase] }
nonisolated struct CardStockResult: Decodable, Sendable { var added: Int; var names: [String] }

nonisolated struct BankActionResult: Decodable, Sendable {
    var processed: Int?
    var expired: Int?
    var nudged: Int?
    var sent: String?
    var now_local: String?
}

nonisolated struct BankBasket: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var store: String

    static let all: [BankBasket] = [
        .init(id: "weekly", title: "Weekly groceries", store: "Avon Fresh Market"),
        .init(id: "quick", title: "Milk, eggs, bread", store: "Corner Pantry Co."),
        .init(id: "taco", title: "Taco night", store: "ValuMart Grocery"),
        .init(id: "oat", title: "Oat milk + bananas", store: "ValuMart Grocery"),
        .init(id: "fuel", title: "Gas (not food)", store: "Avon Fuel Stop"),
    ]
}

@Observable
final class BankStore {
    enum Status: Equatable {
        /// Haven't heard from the server yet.
        case unknown
        /// Server unreachable or misconfigured. Bank features stay out of the way.
        case offline(String)
        /// Server is up, but no one in this household has connected a bank.
        case notLinked
        case linked
    }

    private enum Keys {
        static let server = "bank.serverURL"
        /// From the old standalone Bank tab, which kept its own household.
        static let legacy = ["bank.householdID", "bank.handle", "bank.line", "bank.householdName"]
    }

    /// Build setting DIGIFRIDGEY_SERVER (Config/*.xcconfig → Info.plist), e.g. http://My-Mac.local:8010.
    /// Empty when unset.
    static let buildServer: String = normalizedServer(Bundle.main.object(forInfoDictionaryKey: "DigiFridgeyServer") as? String)

    /// The build setting, else localhost in the Simulator. On a device there is no sensible fallback
    /// (localhost is the phone itself), so it stays empty and Settings says so.
    static var defaultServer: String {
        if !buildServer.isEmpty { return buildServer }
        #if targetEnvironment(simulator)
        return "http://localhost:8010"
        #else
        return ""
        #endif
    }

    /// "my-mac.local:8010" → "http://my-mac.local:8010"; unexpanded build variables → "".
    nonisolated static func normalizedServer(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("$(") else { return "" }
        return s.contains("://") ? s : "http://" + s
    }

    /// Optional operator token (the server's DEMO_TOKEN), sent only as the X-Demo-Token header.
    static let demoToken: String = {
        let raw = ((Bundle.main.object(forInfoDictionaryKey: "DigiFridgeyToken") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("$(") ? "" : raw
    }()

    /// The app's SpacetimeDB token. Every bank request carries it as `Authorization: Bearer`; the server
    /// verifies it with SpacetimeDB and takes the caller (payer, household) from it.
    var tokenProvider: () async -> String? = { nil }

    private func headers() async -> [String: String] {
        var h: [String: String] = [:]
        if !Self.demoToken.isEmpty { h["X-Demo-Token"] = Self.demoToken }
        if let token = await tokenProvider(), !token.isEmpty { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    /// Typed by the user in Settings; saved only when it differs from the build's default.
    var serverURL: String {
        didSet {
            if serverURL == Self.defaultServer {
                UserDefaults.standard.removeObject(forKey: Keys.server)
            } else {
                UserDefaults.standard.set(serverURL, forKey: Keys.server)
            }
        }
    }
    var isServerOverridden: Bool { serverURL != Self.defaultServer }

    func resetServer() {
        serverURL = Self.defaultServer
        Task { await refresh() }
    }

    /// The app household (SpacetimeDB id) the bank is looked up by.
    private(set) var appHouseholdID: String?
    /// This app user's SpacetimeDB identity: picks their own bank when roommates each connected one.
    private(set) var appIdentity: String?
    /// Who owes whom among the roommates sharing this fridge (nil until loaded or when offline).
    private(set) var settle: SettleState?
    private(set) var status: Status = .unknown
    private(set) var state: BankState?
    var isBusy = false

    var household: BankHousehold? { status == .linked ? state?.household : nil }
    var isLinked: Bool { household != nil }
    var handle: String? { state?.handle }
    var line: String? { state?.line }

    init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: Keys.server) ?? Self.defaultServer
        Keys.legacy.forEach(d.removeObject(forKey:))
    }

    // MARK: - Requests

    private func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        let base = Self.normalizedServer(serverURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, var comps = URLComponents(string: base + path), comps.host != nil else {
            throw BankError(message: "Card connection isn't set up in this build. (Developer: enter the server in Settings → Developer & demo tools, or set DIGIFRIDGEY_SERVER in Config/Secrets.xcconfig.)")
        }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return comps.url!
    }

    private func post<T: Decodable>(_ path: String, query: [(String, String)] = [], body: [String: String]? = nil,
                                    headers extra: [String: String] = [:], as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(path, query))
        request.httpMethod = "POST"
        (await headers()).merging(extra) { $1 }.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await APIClient.shared.send(request, as: type)
    }

    /// The server takes the caller's bank household from the bearer token; nothing to send.
    private var bankQuery: [(String, String)] { [] }

    /// Turns the backend's {"detail": "..."} errors into a readable sentence.
    private func message(for error: Error) -> String {
        if let bank = error as? BankError { return bank.message }
        if case APIError.badStatus(401, _) = error {
            return "Your sign-in wasn't accepted. Sign out and back in, then try again."
        }
        if case APIError.badStatus(_, let body) = error,
           let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? String {
            return detail
        }
        if let code = (error as? URLError)?.code, [.cannotConnectToHost, .timedOut, .cannotFindHost].contains(code) {
            return "Card connection is unavailable right now. Try again in a minute. (Can't reach \(serverURL).)"
        }
        return error.localizedDescription
    }

    // MARK: - Household

    /// Keeps the bank in step with the app's household while the app is open.
    func watch(appHouseholdID: String?, appIdentity: String?) async {
        self.appIdentity = appIdentity
        if appHouseholdID != self.appHouseholdID {
            self.appHouseholdID = appHouseholdID
            state = nil
            settle = nil
            status = .unknown
        }
        guard appHouseholdID != nil else { return }
        while !Task.isCancelled {
            await refresh()
            // Linked: keep balances live. Otherwise check now and then whether someone linked by text.
            try? await Task.sleep(for: .seconds(status == .linked ? 4 : 15))
        }
    }

    func refresh() async {
        guard let appHouseholdID else { return }
        do {
            // Who's asking comes from the bearer token, not from query parameters.
            let s = try await APIClient.shared.get(BankState.self, from: try url("/demo/state", [("app_household_id", appHouseholdID)]),
                                                   headers: await headers())
            guard appHouseholdID == self.appHouseholdID else { return }
            state = s
            status = s.household == nil ? .notLinked : .linked
            if s.household != nil { await refreshSettle() }
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            status = .offline(message(for: error))
        }
    }

    // MARK: - Actions

    /// Creates the bank household, gives it an iMessage line and makes it share this app household's fridge.
    /// Returns a sentence for a toast, or throws a readable error.
    func connect(firstName: String, lastName: String, phone: String, inviteCode: String) async throws -> String {
        isBusy = true
        defer { isBusy = false }
        var body = ["first_name": firstName, "phone": phone, "app_invite_code": inviteCode]
        if !lastName.isEmpty { body["last_name"] = lastName }
        let r: BankSignupResponse
        do {
            r = try await post("/signup", body: body, as: BankSignupResponse.self)
        } catch {
            throw BankError(message: message(for: error))
        }
        await refresh()
        if r.app_linked == false {
            throw BankError(message: r.app_link_message ?? "The bank account was created but couldn't join this fridge.")
        }
        let line = PhoneFormat.pretty(r.text_this_number)
        return line.isEmpty ? "Bank connected." : "Bank connected. Text hi to \(line) to start iMessage alerts."
    }

    /// Creates a real Nessie purchase; the backend texts you to confirm what goes in the fridge.
    func buy(_ basket: BankBasket) async throws -> String {
        _ = try await run { try await self.post("/demo/buy", query: [("basket", basket.id)] + self.bankQuery,
                                                 as: BankActionResult.self) }
        return basket.id == "fuel"
            ? "Bought gas at \(basket.store). Not groceries, so the fridge stays the same."
            : "Bought \(basket.title.lowercased()) at \(basket.store). Reply YES to the text, or add items from + → Add from card."
    }

    func advance(days: Int) async throws -> String {
        let r = try await run { try await self.post("/demo/advance", query: [("days", String(days))],
                                                     as: BankActionResult.self) }
        return "Skipped \(days) day\(days == 1 ? "" : "s"). \(r.expired ?? 0) expired, \(r.nudged ?? 0) nudged."
    }

    func sweep() async throws -> String {
        _ = try await run { try await self.post("/demo/sweep", query: self.bankQuery, as: BankActionResult.self) }
        return "Budget sweep offer sent. Reply YES by text to move the money."
    }

    // MARK: - Add from card

    /// Recent grocery card purchases with their products (from the bank transaction).
    func cardPurchases() async throws -> [CardPurchase] {
        do {
            return try await APIClient.shared.get(CardPurchaseList.self, from: try url("/demo/purchases", bankQuery),
                                                  headers: await headers()).purchases
        } catch {
            throw BankError(message: message(for: error))
        }
    }

    /// Adds the chosen lines to the shared fridge; the backend pushes them to the app right away.
    func addFromCard(_ purchase: CardPurchase, lines: Set<Int>) async throws -> String {
        isBusy = true
        defer { isBusy = false }
        var request = URLRequest(url: try url("/demo/purchases/\(purchase.purchase_id)/stock", bankQuery))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        (await headers()).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["lines": Array(lines).sorted()])
        do {
            let r = try await APIClient.shared.send(request, as: CardStockResult.self)
            await refresh()
            return r.added == 0 ? "Those items are already in your fridge."
                : "Added \(r.added) item\(r.added == 1 ? "" : "s") from \(purchase.merchant)."
        } catch {
            throw BankError(message: message(for: error))
        }
    }

    // MARK: - Roommates

    /// The payer is the caller (from the bearer token); only the fridge is named.
    private var settleQuery: [(String, String)] {
        guard let appHouseholdID, household != nil else { return [] }
        return [("app_household_id", appHouseholdID)]
    }

    private(set) var settleError: String?

    func refreshSettle() async {
        guard !settleQuery.isEmpty else { return }
        do {
            settle = try await APIClient.shared.get(SettleState.self, from: try url("/demo/settle", settleQuery),
                                                    headers: await headers())
            settleError = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            settleError = message(for: error)
        }
    }

    /// Sends a roommate what you owe them (a Nessie transfer). Call only after the person confirmed
    /// `quoted` whole dollars. If the split changed since, nothing moves and the error carries the new debt
    /// (`BankError.changedDebt`) so the dialog can ask again.
    func pay(_ debt: SettleDebt, quoted: Int) async throws -> String {
        isBusy = true
        defer { isBusy = false }
        // Re-check right before paying: a refresh may have changed the debt while the dialog was open.
        await refreshSettle()
        let current = settle?.debts.first { $0.id == debt.id }
        if let current, current.wholeDollars != quoted {
            throw BankError(message: "The split changed to $\(current.wholeDollars) since you opened this. Confirm again.",
                            changedDebt: current)
        }
        if current == nil, settle != nil {
            throw BankError(message: "You don't owe \(debt.to_name) anything now, so nothing moved.")
        }
        let r: SettleResult
        do {
            r = try await post("/demo/settle/pay",
                               query: settleQuery + [("to", String(debt.to_id)), ("quoted_amount", String(quoted))],
                               headers: ["Idempotency-Key": UUID().uuidString], as: SettleResult.self)
        } catch {
            throw BankError(message: message(for: error))
        }
        await refresh()
        if r.ok == false {
            // e.g. "The split changed to $X …": show it and re-confirm with the new amount.
            let fresh = settle?.debts.first { $0.id == debt.id }
            throw BankError(message: r.message, changedDebt: fresh.flatMap { $0.wholeDollars >= 1 && $0.wholeDollars != quoted ? $0 : nil })
        }
        return r.message
    }

    /// Texts a roommate who owes you their split, with a YES to pay.
    func ask(_ debt: SettleDebt) async throws -> String {
        try await guarded { try await self.post("/demo/settle/ask", query: self.settleQuery + [("debtor", String(debt.from_id))],
                                                as: SettleResult.self) }.message
    }

    /// Demo: a roommate with their own card joins this fridge and buys groceries.
    func addRoommate(name: String) async throws -> String {
        guard let appHouseholdID else { throw BankError(message: "Join a household first.") }
        let r = try await guarded { try await self.post("/demo/roommate", query: [("app_household_id", appHouseholdID), ("name", name)],
                                                        as: RoommateResult.self) }
        await refresh()
        return "\(r.name) joined with their own card and stocked \(r.stocked) items."
    }

    /// Demo: a roommate texts USED <item>.
    func roommateUses(_ roommate: SettleRoommate, item: String) async throws -> String {
        // Names the demo roommate who used it (not the caller); the server checks they share the caller's fridge.
        let r = try await guarded { try await self.post("/demo/roommate/use", query: [("household_id", String(roommate.id))],
                                                        body: ["item": item], as: RoommateUseResult.self) }
        await refresh()
        return "\(roommate.name): \(r.reply)"
    }

    private func guarded<T>(_ work: @escaping () async throws -> T) async throws -> T {
        isBusy = true
        defer { isBusy = false }
        do { return try await work() } catch { throw BankError(message: message(for: error)) }
    }

    private func run(_ work: @escaping () async throws -> BankActionResult) async throws -> BankActionResult {
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await work()
            await refresh()
            return r
        } catch {
            throw BankError(message: message(for: error))
        }
    }
}

struct BankError: LocalizedError {
    var message: String
    /// Set when a payment didn't go through because the amount changed: the debt to confirm again.
    var changedDebt: SettleDebt? = nil
    var errorDescription: String? { message }
}

enum PhoneFormat {
    /// "+14695550123" -> "(469) 555-0123"; anything else is returned as is.
    static func pretty(_ s: String?) -> String {
        guard let s else { return "" }
        let digits = s.filter(\.isNumber)
        guard s.hasPrefix("+1"), digits.count == 11 else { return s }
        let d = Array(digits.dropFirst())
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}
