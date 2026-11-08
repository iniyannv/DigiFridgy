import Foundation
import FirebaseCore

/// Service container. Views reach it through `AppState` from the SwiftUI environment.
final class AppServices {
    let isMock: Bool
    let auth: any AuthService
    let repository: any HouseholdRepository
    let products: any ProductLookupService
    let recipes: any RecipeService
    let recalls: any RecallService
    let kroger: any KrogerService
    let walmart: any WalmartService
    /// Stores tab product search (Traject Data BlueCart / RedCircle, or samples).
    let walmartSearch: any ProductSearchService
    let targetSearch: any ProductSearchService
    let storeSearch: any StoreSearchService
    let location: any LocationService
    let ocr: any ReceiptTextRecognizer
    let normalizer: any ReceiptNormalizer
    let notifications: any NotificationService

    let shelfLife = ShelfLifeService.shared
    let mockPrices = MockPriceService()
    /// User corrections to scanned products, re-applied on every scan of the same barcode.
    let productOverrides: ProductOverrideStore = AppServices.isRunningTests ? ProductOverrideStore(fileURL: nil) : .shared
    let scorer = RecipeScorer()
    let recallMatcher = RecallMatcher()
    let parser = ReceiptParser()

    init(isMock: Bool, auth: any AuthService, repository: any HouseholdRepository,
         products: any ProductLookupService, recipes: any RecipeService, recalls: any RecallService,
         kroger: any KrogerService, storeSearch: any StoreSearchService, location: any LocationService,
         ocr: any ReceiptTextRecognizer, normalizer: any ReceiptNormalizer, notifications: any NotificationService,
         walmart: any WalmartService = MockWalmartService(),
         walmartSearch: any ProductSearchService = MockProductSearchService(retailer: .walmart),
         targetSearch: any ProductSearchService = MockProductSearchService(retailer: .target)) {
        self.isMock = isMock
        self.auth = auth
        self.repository = repository
        self.products = products
        self.recipes = recipes
        self.recalls = recalls
        self.kroger = kroger
        self.walmart = walmart
        self.walmartSearch = walmartSearch
        self.targetSearch = targetSearch
        self.storeSearch = storeSearch
        self.location = location
        self.ocr = ocr
        self.normalizer = normalizer
        self.notifications = notifications
    }

    static let mockDefaultsKey = "useMocks"

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var hasFirebaseConfig: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    /// Debug (demo) builds offer the "Offline mock mode" switch; release builds never read it.
    static var isDemoBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Mock mode: `--mock` launch argument, the Settings toggle (demo builds only), running tests,
    /// or no SpacetimeDB config.
    static var shouldUseMocks: Bool {
        if !isDemoBuild, UserDefaults.standard.object(forKey: mockDefaultsKey) != nil {
            // A switch left on by a demo build must not force a live build into sample data.
            UserDefaults.standard.removeObject(forKey: mockDefaultsKey)
        }
        return ProcessInfo.processInfo.arguments.contains("--mock")
            || (isDemoBuild && UserDefaults.standard.bool(forKey: mockDefaultsKey))
            || isRunningTests
            || !Secrets.hasSpacetime
    }

    static func makeDefault() -> AppServices {
        guard !shouldUseMocks, let spacetime = SpacetimeClient.configured() else { return mock() }
        return live(spacetime: spacetime)
    }

    /// SpacetimeDB for household data. Sign-in uses Firebase Auth when GoogleService-Info.plist is present
    /// (its ID token is the SpacetimeDB bearer token), otherwise a SpacetimeDB-issued identity.
    /// Individual APIs whose keys are missing fall back to their mocks.
    static func live(spacetime: SpacetimeClient) -> AppServices {
        let auth: any AuthService
        if hasFirebaseConfig {
            if FirebaseApp.app() == nil { FirebaseApp.configure() }
            auth = FirebaseAuthService()
        } else {
            auth = SpacetimeAuthService(client: spacetime)
        }
        spacetime.tokenProvider = { [weak auth] in try await auth?.idToken() }
        return AppServices(
            isMock: false,
            auth: auth,
            repository: SpacetimeHouseholdRepository(client: spacetime),
            products: LiveProductLookupService(),
            recipes: Secrets.hasEdamam ? EdamamRecipeService() : MockRecipeService(),
            recalls: OpenFDARecallService(),
            kroger: Secrets.hasKroger ? LiveKrogerService() : MockKrogerService(),
            storeSearch: MapKitStoreSearchService(),
            location: CoreLocationService(),
            ocr: VisionReceiptTextRecognizer(),
            normalizer: SmartReceiptNormalizer(),
            notifications: LocalNotificationService(),
            walmart: Secrets.hasWalmart ? LiveWalmartService() : MockWalmartService(),
            walmartSearch: Secrets.hasBlueCart ? LiveTrajectSearchService(.blueCart)
                                               : MockProductSearchService(retailer: .walmart),
            targetSearch: Secrets.hasRedCircle ? LiveTrajectSearchService(.redCircle)
                                               : MockProductSearchService(retailer: .target)
        )
    }

    /// Fully offline. Local notifications, OCR and the on-device model still work offline, so they stay real.
    static func mock() -> AppServices {
        AppServices(
            isMock: true,
            auth: MockAuthService(),
            repository: MockHouseholdRepository(persist: !isRunningTests),
            products: MockProductLookupService(),
            recipes: MockRecipeService(),
            recalls: MockRecallService(),
            kroger: MockKrogerService(),
            storeSearch: MockStoreSearchService(),
            location: MockLocationService(),
            ocr: VisionReceiptTextRecognizer(),
            normalizer: isRunningTests ? MockReceiptNormalizer() : SmartReceiptNormalizer(),
            notifications: isRunningTests ? MockNotificationService() : LocalNotificationService()
        )
    }

    /// Short human-readable status for Settings: (service, live). Not live = sample data.
    var statusLines: [(String, Bool)] {
        [
            ("SpacetimeDB (household sync)", !isMock),
            ("Firebase Auth (email sign-in)", !isMock && Self.hasFirebaseConfig),
            ("Open Food Facts", !isMock),
            ("CalorieNinjas", !isMock && Secrets.hasCalorieNinjas),
            ("Edamam recipes", !isMock && Secrets.hasEdamam),
            ("Kroger prices", !isMock && Secrets.hasKroger),
            ("Walmart.com prices", !isMock && Secrets.hasWalmart),
            ("Walmart search (BlueCart)", walmartSearch.isLive),
            ("Target search (RedCircle)", targetSearch.isLive),
            // USDA FSIS (meat, poultry, egg products) has no public API an app can call.
            ("Recalls: FDA only (openFDA)", !isMock),
            // Hidden while receipt scanning is hidden from users.
            // ("On-device model (receipts)", normalizer.usesOnDeviceModel),
        ]
    }
}
