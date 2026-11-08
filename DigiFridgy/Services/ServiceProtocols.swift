import Foundation
import CoreGraphics

// Every service is protocol-backed with a live and a mock implementation.
// `AppServices` picks which set to use (see `--mock` launch argument / Settings toggle).

nonisolated struct AuthUser: Equatable, Sendable {
    var uid: String
    var email: String?
    var isAnonymous: Bool
}

protocol AuthService: AnyObject, Sendable {
    var currentUser: AuthUser? { get }
    /// Whether email/password sign-in is available (Firebase only).
    var supportsEmail: Bool { get }
    /// OIDC token sent to SpacetimeDB as `Authorization: Bearer` (refreshed as needed).
    func idToken() async throws -> String?
    func signInAnonymously() async throws -> AuthUser
    func signIn(email: String, password: String) async throws -> AuthUser
    func signUp(email: String, password: String) async throws -> AuthUser
    /// Upgrades an anonymous account to email/password, keeping the same uid.
    func linkEmail(email: String, password: String) async throws -> AuthUser
    func signOut() throws
}

protocol HouseholdRepository: AnyObject, Sendable {
    func profile(uid: String) async throws -> UserProfile?
    func saveProfile(_ profile: UserProfile) async throws

    func createHousehold(name: String, ownerUid: String) async throws -> Household
    func joinHousehold(code: String, uid: String) async throws -> Household
    func household(id: String) async throws -> Household?
    func leaveHousehold(id: String, uid: String) async throws

    func itemsStream(householdId: String) -> AsyncThrowingStream<[FridgeItem], any Error>
    func fetchItems(householdId: String) async throws -> [FridgeItem]
    func saveItem(_ item: FridgeItem, householdId: String) async throws
    func saveItems(_ items: [FridgeItem], householdId: String) async throws
    func incrementCount(itemId: String, by delta: Int, householdId: String) async throws
    func deleteItem(id: String, householdId: String) async throws
    /// Someone in the household used `qty` of an item (−1). Records who used it where the backend supports it,
    /// so roommates can split what they ate; removes the item when `remaining` reaches zero.
    func useItem(id: String, qty: Int, name: String, remaining: Int, householdId: String) async throws
    /// The signed-in user's identity in the household database (hex), when there is one.
    var identityHex: String? { get }

    /// Questions waiting on a YES for this household (see `Approval`).
    func approvalsStream(householdId: String) -> AsyncStream<[Approval]>
    func decideApproval(id: String, approve: Bool) async throws

    func shoppingStream(householdId: String) -> AsyncThrowingStream<[ShoppingListItem], any Error>
    func saveShoppingItem(_ item: ShoppingListItem, householdId: String) async throws
    func deleteShoppingItem(id: String, householdId: String) async throws

    func priceHistory(upc: String, householdId: String) async throws -> PriceHistory?
    func savePriceHistory(_ history: PriceHistory, householdId: String) async throws
}

extension HouseholdRepository {
    func useItem(id: String, qty: Int, name: String, remaining: Int, householdId: String) async throws {
        if remaining <= 0 {
            try await deleteItem(id: id, householdId: householdId)
        } else {
            try await incrementCount(itemId: id, by: -qty, householdId: householdId)
        }
    }

    var identityHex: String? { nil }

    func approvalsStream(householdId: String) -> AsyncStream<[Approval]> { AsyncStream { $0.finish() } }
    func decideApproval(id: String, approve: Bool) async throws {}
}

protocol ProductLookupService: AnyObject, Sendable {
    /// Open Food Facts lookup. Returns nil when the product is unknown.
    func lookup(barcode: String) async throws -> ProductInfo?
    /// CalorieNinjas lookup by free-text name (receipt items, unknown barcodes).
    func nutrition(forName name: String) async throws -> Nutrition?
}

protocol RecipeService: AnyObject, Sendable {
    /// Runs the request's queries with its filters and returns de-duplicated recipes, mixed across queries.
    func search(_ request: RecipeSearchRequest, userId: String?) async throws -> [Recipe]
}

protocol RecallService: AnyObject, Sendable {
    func recentRecalls(days: Int) async throws -> [Recall]
}

/// A live price from a store API (Kroger per store, Walmart per product).
nonisolated struct KrogerPrice: Sendable {
    var regular: Double
    var promo: Double?
    var description: String?
}

protocol KrogerService: AnyObject, Sendable {
    var isLive: Bool { get }
    func locations(near: Coordinate, radiusMiles: Double, limit: Int) async throws -> [Store]
    func price(upc: String?, term: String, locationId: String) async throws -> KrogerPrice?
}

/// walmart.com prices: one per product (not per store), shown on every nearby Walmart as an online price.
protocol WalmartService: AnyObject, Sendable {
    var isLive: Bool { get }
    /// Current walmart.com price, or nil when Walmart has no matching item.
    func price(upc: String?, term: String) async throws -> KrogerPrice?
}

protocol StoreSearchService: AnyObject, Sendable {
    func stores(near: Coordinate, radiusMiles: Double, chains: [OtherChain]) async -> [Store]
}

protocol LocationService: AnyObject, Sendable {
    /// Best-effort current coordinate; nil when permission is denied or unavailable.
    func currentCoordinate() async -> Coordinate?
}

protocol ReceiptTextRecognizer: AnyObject, Sendable {
    /// OCR → visual lines of text, top to bottom.
    func recognizeLines(in image: CGImage) async throws -> [String]
}

protocol ReceiptNormalizer: AnyObject, Sendable {
    var usesOnDeviceModel: Bool { get }
    /// Turns raw receipt line names ("GV 2% MLK GAL") into readable names + category ids.
    func normalize(_ lines: [ParsedReceiptLine]) async -> [NormalizedReceiptLine]
}

protocol NotificationService: AnyObject, Sendable {
    func requestAuthorization() async -> Bool
    /// Current permission (false = denied or not asked yet).
    func isAuthorized() async -> Bool
    /// Makes pending expiry reminders match the household's items (adds, replaces, removes).
    func reconcile(items: [FridgeItem]) async
    /// Removes every pending reminder (sign-out, leaving the household).
    func removeAllReminders()
    func notifyNow(id: String, title: String, body: String)
    /// Clears posted (and still pending) notifications, e.g. a recall alert the user dismissed.
    func removeNotifications(ids: [String])
}

extension NotificationService {
    func removeNotifications(ids: [String]) {}
}

nonisolated enum HouseholdError: LocalizedError {
    case codeNotFound
    case noHousehold

    var errorDescription: String? {
        switch self {
        case .codeNotFound: "That code didn't match a household. Check the 6 letters and numbers with whoever shared it."
        case .noHousehold: "Join or create a household first."
        }
    }
}
