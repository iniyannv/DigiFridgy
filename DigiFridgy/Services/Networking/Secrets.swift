import Foundation

/// Keys injected from `Config/Secrets.xcconfig` → Info.plist.
/// DEMO ONLY: anything in the app bundle can be extracted. Use a backend proxy for a real release.
nonisolated enum Secrets {
    static var edamamAppID: String { value("EdamamAppID") }
    static var edamamAppKey: String { value("EdamamAppKey") }
    static var krogerClientID: String { value("KrogerClientID") }
    static var krogerClientSecret: String { value("KrogerClientSecret") }
    static var calorieNinjasKey: String { value("CalorieNinjasKey") }

    static var hasEdamam: Bool { !edamamAppID.isEmpty && !edamamAppKey.isEmpty }
    static var hasKroger: Bool { !krogerClientID.isEmpty && !krogerClientSecret.isEmpty }
    static var hasCalorieNinjas: Bool { !calorieNinjasKey.isEmpty }

    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded build variable means the key was never set.
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
