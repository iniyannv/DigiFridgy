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
    let storeSearch: any StoreSearchService
    let location: any LocationService
    let ocr: any ReceiptTextRecognizer
    let normalizer: any ReceiptNormalizer
    let notifications: any NotificationService

    let shelfLife = ShelfLifeService.shared
    let mockPrices = MockPriceService()
    let scorer = RecipeScorer()
    let recallMatcher = RecallMatcher()
    let parser = ReceiptParser()

    init(isMock: Bool, auth: any AuthService, repository: any HouseholdRepository,
         products: any ProductLookupService, recipes: any RecipeService, recalls: any RecallService,
         kroger: any KrogerService, storeSearch: any StoreSearchService, location: any LocationService,
         ocr: any ReceiptTextRecognizer, normalizer: any ReceiptNormalizer, notifications: any NotificationService) {
        self.isMock = isMock
        self.auth = auth
        self.repository = repository
        self.products = products
        self.recipes = recipes
        self.recalls = recalls
        self.kroger = kroger
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

    /// Mock mode: `--mock` launch argument, the Settings toggle, running tests, or no Firebase config.
    static var shouldUseMocks: Bool {
        ProcessInfo.processInfo.arguments.contains("--mock")
            || UserDefaults.standard.bool(forKey: mockDefaultsKey)
            || isRunningTests
            || !hasFirebaseConfig
    }

    static func makeDefault() -> AppServices {
        if shouldUseMocks { return mock() }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        return live()
    }

    /// Live Firebase + APIs. Individual APIs whose keys are missing fall back to their mocks.
    static func live() -> AppServices {
        AppServices(
            isMock: false,
            auth: FirebaseAuthService(),
            repository: FirestoreHouseholdRepository(),
            products: LiveProductLookupService(),
            recipes: Secrets.hasEdamam ? EdamamRecipeService() : MockRecipeService(),
            recalls: OpenFDARecallService(),
            kroger: Secrets.hasKroger ? LiveKrogerService() : MockKrogerService(),
            storeSearch: MapKitStoreSearchService(),
            location: CoreLocationService(),
            ocr: VisionReceiptTextRecognizer(),
            normalizer: SmartReceiptNormalizer(),
            notifications: LocalNotificationService()
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

    /// Short human-readable status for Settings.
    var statusLines: [(String, Bool)] {
        [
            ("Firebase (auth + sync)", !isMock),
            ("Open Food Facts", !isMock),
            ("CalorieNinjas", !isMock && Secrets.hasCalorieNinjas),
            ("Edamam recipes", !isMock && Secrets.hasEdamam),
            ("Kroger prices", !isMock && Secrets.hasKroger),
            ("openFDA recalls", !isMock),
            ("On-device model (receipts)", normalizer.usesOnDeviceModel),
        ]
    }
}
