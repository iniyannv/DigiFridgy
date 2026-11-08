import Foundation

/// Keys injected from `Config/Secrets.xcconfig` → Info.plist.
/// DEMO ONLY: anything in the app bundle can be extracted. Use a backend proxy for a real release.
nonisolated enum Secrets {
    static var edamamAppID: String { value("EdamamAppID") }
    static var edamamAppKey: String { value("EdamamAppKey") }
    static var krogerClientID: String { value("KrogerClientID") }
    static var krogerClientSecret: String { value("KrogerClientSecret") }
    static var calorieNinjasKey: String { value("CalorieNinjasKey") }
    static var walmartConsumerID: String { value("WalmartConsumerID") }
    static var walmartKeyVersion: String { value("WalmartKeyVersion").isEmpty ? "1" : value("WalmartKeyVersion") }
    /// Base64url DER of the RSA private key (see Secrets.example.xcconfig).
    static var walmartPrivateKey: String { value("WalmartPrivateKey") }
    /// Traject Data BlueCart (Walmart search) and RedCircle (Target search): one key each.
    static var blueCartAPIKey: String { value("BlueCartAPIKey") }
    static var redCircleAPIKey: String { value("RedCircleAPIKey") }

    static var spacetimeHost: String { value("SpacetimeHost") }
    static var spacetimeDatabase: String { value("SpacetimeDatabase") }

    static var hasSpacetime: Bool { !spacetimeHost.isEmpty && !spacetimeDatabase.isEmpty }
    static var hasEdamam: Bool { !edamamAppID.isEmpty && !edamamAppKey.isEmpty }
    static var hasKroger: Bool { !krogerClientID.isEmpty && !krogerClientSecret.isEmpty }
    static var hasCalorieNinjas: Bool { !calorieNinjasKey.isEmpty }
    static var hasWalmart: Bool { !walmartConsumerID.isEmpty && !walmartPrivateKey.isEmpty }
    static var hasBlueCart: Bool { !blueCartAPIKey.isEmpty }
    static var hasRedCircle: Bool { !redCircleAPIKey.isEmpty }

    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded build variable means the key was never set.
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
