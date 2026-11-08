import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                VStack(spacing: 16) {
                    Image(systemName: "refrigerator.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    ProgressView("Opening your fridge…")
                        .foregroundStyle(.secondary)
                }
            case .onboarding:
                OnboardingView()
            case .householdSetup:
                HouseholdSetupView()
            case .ready:
                MainTabView()
            }
        }
        .animation(.default, value: app.phase)
        .toastOverlay()
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank

    var body: some View {
        TabView {
            Tab("Fridge", systemImage: "refrigerator") {
                InventoryView()
            }
            Tab("Recipes", systemImage: "fork.knife") {
                RecipesView()
            }
            Tab("Stores", systemImage: "cart") {
                StoresTabView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: app.householdId) {
            // Bank requests carry the same token the app uses for SpacetimeDB; the server verifies it.
            bank.tokenProvider = { [auth = app.services.auth] in try? await auth.idToken() }
            await bank.watch(appHouseholdID: app.householdId, appIdentity: app.services.repository.identityHex)
        }
    }
}
