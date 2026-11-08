import Foundation

nonisolated enum SpacetimeError: LocalizedError {
    case notConfigured
    case notSignedIn
    case unauthorized(String)
    case reducer(String)
    case server(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "SpacetimeDB isn't configured. Set SPACETIME_HOST and SPACETIME_DB."
        case .notSignedIn: "You're not signed in."
        case .unauthorized(let detail): "SpacetimeDB rejected the sign-in token. \(detail.prefix(120))"
        case .reducer(let message): message
        case .server(let code, let body): "SpacetimeDB error \(code). \(body.prefix(140))"
        case .badResponse(let detail): "Unexpected SpacetimeDB response: \(detail)"
        }
    }
}

/// Minimal SpacetimeDB 2.x client over the HTTP API:
/// reducers via `POST /v1/database/:db/call/:reducer` (JSON array args),
/// reads via `POST /v1/database/:db/sql` against per-caller views.
/// Each request carries the caller's OIDC token (Firebase ID token or a SpacetimeDB identity token).
final class SpacetimeClient {
    typealias Row = [String: Any]

    let baseURL: URL
    let database: String
    /// Returns the bearer token for the signed-in user (nil = not signed in).
    var tokenProvider: () async throws -> String? = { nil }

    private let session: URLSession

    init(host: String, database: String, session: URLSession = .shared) {
        let scheme = host.hasPrefix("localhost") || host.hasPrefix("127.") ? "http" : "https"
        baseURL = URL(string: "\(scheme)://\(host)")!
        self.database = database
        self.session = session
    }

    static func configured() -> SpacetimeClient? {
        guard Secrets.hasSpacetime else { return nil }
        return SpacetimeClient(host: Secrets.spacetimeHost, database: Secrets.spacetimeDatabase)
    }

    // MARK: Identity

    /// `POST /v1/identity` → a fresh anonymous SpacetimeDB identity + token.
    func createIdentity() async throws -> (identity: String, token: String) {
        var request = URLRequest(url: baseURL.appending(path: "v1/identity"))
        request.httpMethod = "POST"
        let data = try await perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = json["identity"] as? String, let token = json["token"] as? String else {
            throw SpacetimeError.badResponse("identity")
        }
        return (identity, token)
    }

    // MARK: Reducers

    /// Calls a reducer. Arguments must be JSON-serializable (String, numbers, Bool, arrays of those).
    func call(_ reducer: String, _ args: [Any]) async throws {
        var request = try await authorizedRequest(path: "v1/database/\(database)/call/\(reducer)")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        _ = try await perform(request)
    }

    // MARK: SQL

    /// Runs one SQL statement and returns rows keyed by column name.
    func query(_ sql: String) async throws -> [Row] {
        var request = try await authorizedRequest(path: "v1/database/\(database)/sql")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(sql.utf8)
        let data = try await perform(request)
        guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = results.first,
              let schema = first["schema"] as? [String: Any],
              let elements = schema["elements"] as? [[String: Any]],
              let rows = first["rows"] as? [[Any]] else {
            throw SpacetimeError.badResponse("sql")
        }
        let names: [String] = elements.enumerated().map { index, element in
            let name = element["name"] as? [String: Any]
            return (name?["some"] as? String) ?? "col\(index)"
        }
        return rows.map { values in
            var row: Row = [:]
            for (index, value) in values.enumerated() where index < names.count {
                row[names[index]] = Self.unwrapOption(value)
            }
            return row
        }
    }

    // MARK: Plumbing

    private func authorizedRequest(path: String) async throws -> URLRequest {
        guard let token = try await tokenProvider() else { throw SpacetimeError.notSignedIn }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        switch status {
        case 200..<300: return data
        case 401, 403: throw SpacetimeError.unauthorized(body)
        case 530: throw SpacetimeError.reducer(body.isEmpty ? "Request was rejected." : body)
        default: throw SpacetimeError.server(status, body)
        }
    }

    /// SATS-JSON encodes Option as {"some": v} / {"none": []}.
    nonisolated static func unwrapOption(_ value: Any) -> Any {
        if let dict = value as? [String: Any], dict.count == 1 {
            if let some = dict["some"] { return some }
            if dict["none"] != nil { return NSNull() }
        }
        return value
    }
}

nonisolated extension SpacetimeClient.Row {
    func string(_ key: String) -> String { (self[key] as? String) ?? "" }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func double(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func date(_ key: String) -> Date { Date(timeIntervalSince1970: Double(int(key)) / 1000) }
    func strings(_ key: String) -> [String] { (self[key] as? [String]) ?? [] }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? ((self[key] as? NSNumber)?.boolValue ?? false) }
}

nonisolated struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Couldn't save your sign-in to the Keychain (\(detail))."
    }
}

/// Tiny generic-password Keychain wrapper (SpacetimeDB identity token).
/// Items stay on this device (`ThisDeviceOnly`): they aren't in backups or iCloud Keychain.
nonisolated enum Keychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.iniyann.digifridgy",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) throws {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.iniyann.digifridgy",
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.iniyann.digifridgy",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
