import SwiftUI
import UserNotifications

@main
struct DigiFridgyApp: App {
    @State private var appState: AppState
    @State private var bankStore = BankStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = AppState(services: AppServices.makeDefault())
        UNUserNotificationCenter.current().delegate = state.notificationDelegate
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        let state = appState
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(bankStore)
                .task { await appState.bootstrap() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { appState.scheduleBackgroundRefresh() }
        }
        // BGAppRefreshTask: recalls + watched prices. Unreliable on demand — Settings has "Run checks now".
        .backgroundTask(.appRefresh(AppState.refreshTaskID)) {
            await state.runBackgroundChecks()
        }
    }
}
