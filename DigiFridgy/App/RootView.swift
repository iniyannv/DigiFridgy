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
    /// Distance scrolled in the current direction (negative = up), so a slow, slight scroll still counts.
    @State private var travel: CGFloat = 0

    /// How far up (in points) before the bar expands.
    static let upThreshold: CGFloat = 10

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            // Clamped to the scrollable range, so the bounce at either end doesn't count as scrolling.
            let maxOffset = max(0, geometry.contentSize.height + geometry.contentInsets.top
                                    + geometry.contentInsets.bottom - geometry.containerSize.height)
            return min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), maxOffset)
        } action: { old, new in
            guard let tabBar else { return }
            let delta = new - old
            guard delta != 0 else { return }
            // Start counting again whenever the direction changes.
            travel = (travel < 0) == (delta < 0) ? travel + delta : delta
            if new <= 0 {
                // At the top the system expands it anyway; hand control back.
                if tabBar.scrollingUp { tabBar.scrollingUp = false }
            } else if travel <= -Self.upThreshold, !tabBar.scrollingUp {
                tabBar.scrollingUp = true
                // Once it has expanded, hand control back to the system so the very next scroll down
                // minimizes it again (it stays expanded until then).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    tabBar.scrollingUp = false
                }
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
