import Foundation
import Observation

// Talks to the DigiFridgey backend (backend/ folder): phone sign-up, the
// bank-stocked fridge, Nessie balances, and the demo controls.

nonisolated struct BankSignupResponse: Decodable, Sendable {
    var household: String
    var household_id: Int
    var handle: String
    var text_this_number: String?
    var line_error: String?
    var simulated: Bool
    var existing: Bool
}

nonisolated struct BankFridgeItem: Decodable, Sendable, Hashable {
    var name: String
    var emoji: String
    var expires: String
    var price: Double
}

nonisolated struct BankHousehold: Decodable, Sendable {
    var id: Int
    var name: String
    var budget: Double
    var members: [String]
    var fridge: [BankFridgeItem]
    var list: [String]
    var waste_total: Double
    var week_spend: Double
    var week_waste: Double
    var checking_balance: Double?
    var fund_balance: Double?
}

nonisolated struct BankState: Decodable, Sendable {
    var now_local: String
    var offset_days: Double
    var mock_nessie: Bool
    var mock_photon: Bool
    var household: BankHousehold?
}

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
    private enum Keys {
        static let server = "bank.serverURL"
        static let householdID = "bank.householdID"
        static let handle = "bank.handle"
        static let line = "bank.line"
        static let name = "bank.householdName"
    }

    /// Build setting DIGIFRIDGEY_SERVER (via Info.plist) lets a device build point at the Mac,
    /// e.g. http://My-Mac.local:8010. The simulator falls back to localhost.
    static let defaultServer: String = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "DigiFridgeyServer") as? String) ?? ""
        return s.hasPrefix("http") ? s : "http://localhost:8010"
    }()

    /// Matches the server's DEMO_TOKEN, so other people on the Wi-Fi can't drive the demo.
    static let token: String = (Bundle.main.object(forInfoDictionaryKey: "DigiFridgeyToken") as? String) ?? ""

    private var authHeaders: [String: String] { Self.token.isEmpty ? [:] : ["X-Demo-Token": Self.token] }

    var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: Keys.server) } }
    private(set) var householdID: Int?
    private(set) var handle: String?
    private(set) var line: String?
    private(set) var householdName: String?

    var state: BankState?
    var lastError: String?
    var isBusy = false

    var isLinked: Bool { householdID != nil }

    init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: Keys.server) ?? Self.defaultServer
        householdID = d.object(forKey: Keys.householdID) as? Int
        handle = d.string(forKey: Keys.handle)
        line = d.string(forKey: Keys.line)
        householdName = d.string(forKey: Keys.name)
    }

    // MARK: - Requests

    private func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        let base = serverURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: base + path), comps.host != nil else {
            throw APIError.notConfigured("Server address")
        }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return comps.url!
    }

    private func post<T: Decodable>(_ path: String, query: [(String, String)] = [], body: [String: String]? = nil,
                                    as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(path, query))
        request.httpMethod = "POST"
        authHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await APIClient.shared.send(request, as: type)
    }

    private var householdQuery: [(String, String)] {
        householdID.map { [("household_id", String($0))] } ?? []
    }

    /// Turns the backend's {"detail": "..."} errors into a readable sentence.
    private func message(for error: Error) -> String {
        if case APIError.badStatus(_, let body) = error,
           let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? String {
            return detail
        }
        if (error as? URLError)?.code == .cannotConnectToHost || (error as? URLError)?.code == .timedOut {
            return "Can't reach the DigiFridgey server at \(serverURL). Is it running?"
        }
        return error.localizedDescription
    }

    // MARK: - Actions

    func signUp(firstName: String, lastName: String, phone: String) async -> BankSignupResponse? {
        isBusy = true
        defer { isBusy = false }
        do {
            var body = ["first_name": firstName, "phone": phone]
            if !lastName.isEmpty { body["last_name"] = lastName }
            let r = try await post("/signup", body: body, as: BankSignupResponse.self)
            householdID = r.household_id
            handle = r.handle
            line = r.text_this_number
            householdName = r.household
            let d = UserDefaults.standard
            d.set(r.household_id, forKey: Keys.householdID)
            d.set(r.handle, forKey: Keys.handle)
            d.set(r.text_this_number, forKey: Keys.line)
            d.set(r.household, forKey: Keys.name)
            lastError = nil
            await refresh()
            return r
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    func unlink() {
        householdID = nil
        handle = nil
        line = nil
        householdName = nil
        state = nil
        for key in [Keys.householdID, Keys.handle, Keys.line, Keys.name] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func refresh() async {
        guard isLinked else { return }
        do {
            state = try await APIClient.shared.get(BankState.self, from: try url("/demo/state", householdQuery),
                                                   headers: authHeaders)
            lastError = nil
        } catch {
            lastError = message(for: error)
        }
    }

    /// Creates a real Nessie purchase; the backend stocks the fridge and texts you.
    func buy(_ basket: BankBasket) async -> String? {
        await run { try await self.post("/demo/buy", query: [("basket", basket.id)] + self.householdQuery,
                                         as: BankActionResult.self) }
            .map { _ in "Bought \(basket.title.lowercased()) at \(basket.store). Check your texts." }
    }

    func advance(days: Int) async -> String? {
        await run { try await self.post("/demo/advance", query: [("days", String(days))], as: BankActionResult.self) }
            .map { r in "Skipped \(days) day\(days == 1 ? "" : "s"). \(r.expired ?? 0) expired, \(r.nudged ?? 0) nudged." }
    }

    func sweep() async -> String? {
        await run { try await self.post("/demo/sweep", query: self.householdQuery, as: BankActionResult.self) }
            .map { _ in "Budget sweep offer sent. Reply YES by text to move the money." }
    }

    private func run(_ work: @escaping () async throws -> BankActionResult) async -> BankActionResult? {
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await work()
            lastError = nil
            await refresh()
            return r
        } catch {
            lastError = message(for: error)
            return nil
        }
    }
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
