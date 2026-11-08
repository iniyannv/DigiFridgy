import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView()
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
    }
}
