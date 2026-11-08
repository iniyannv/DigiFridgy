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
        .toastWindow(app)
    }
}

/// Scroll direction shared by the tab screens, so the minimized tab bar expands again as soon as
/// you scroll back up (the system only expands it once you reach the top).
@Observable
final class TabBarScrollState {
    var scrollingUp = false
}

private struct ExpandsTabBarOnScrollUp: ViewModifier {
    @Environment(TabBarScrollState.self) private var tabBar: TabBarScrollState?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            // Clamped to the scrollable range, so the bounce at either end doesn't count as scrolling.
            let maxOffset = max(0, geometry.contentSize.height + geometry.contentInsets.top
                                    + geometry.contentInsets.bottom - geometry.containerSize.height)
            return min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), maxOffset)
        } action: { old, new in
            guard let tabBar else { return }
            let delta = new - old
            // Animated, so expanding plays the same spring as the system's collapse instead of snapping open.
            if new <= 0 {
                // At the top the system expands it anyway; hand control back.
                if tabBar.scrollingUp { withAnimation(.smooth(duration: 0.35)) { tabBar.scrollingUp = false } }
            } else if delta < -4, !tabBar.scrollingUp {
                withAnimation(.smooth(duration: 0.35)) { tabBar.scrollingUp = true }
            } else if delta > 4, tabBar.scrollingUp {
                withAnimation(.smooth(duration: 0.35)) { tabBar.scrollingUp = false }
            }
        }
    }
}

extension View {
    /// Re-expands the minimized tab bar when this scroll view scrolls up.
    func expandsTabBarOnScrollUp() -> some View { modifier(ExpandsTabBarOnScrollUp()) }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @Environment(BankStore.self) private var bank
    @State private var tabBar = TabBarScrollState()

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
        // Scrolling up switches minimizing off, which expands the bar; scrolling down turns it back on.
        .tabBarMinimizeBehavior(tabBar.scrollingUp ? .never : .onScrollDown)
        .environment(tabBar)
        .task(id: app.householdId) {
            // Bank requests carry the same token the app uses for SpacetimeDB; the server verifies it.
            bank.tokenProvider = { [auth = app.services.auth] in try? await auth.idToken() }
            await bank.watch(appHouseholdID: app.householdId, appIdentity: app.services.repository.identityHex)
        }
    }
}
