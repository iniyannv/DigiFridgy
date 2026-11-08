import Testing
import Foundation
@testable import DigiFridgy

/// Expiry reminders follow the shared fridge, not just what this phone saved.
@MainActor
struct ReminderSyncTests {
    @Test func remindersFollowItemsAddedAndRemovedElsewhere() async throws {
        let services = AppServices.mock()
        let notifications = try #require(services.notifications as? MockNotificationService)
        let app = AppState(services: services)
        await app.signInAnonymously()
        await app.createHousehold(name: "Reminder Test")
        let hid = try #require(app.householdId)

        // A roommate (or a card purchase) adds milk from somewhere else.
        let milk = FridgeItem(name: "Milk", category: "milk", expiresAt: .now.addingTimeInterval(5 * 86_400),
                              source: .receipt)
        try await services.repository.saveItem(milk, householdId: hid)
        try await waitUntil { notifications.log.contains("schedule \(milk.id)") }

        // Then someone else uses it up: its reminder goes away.
        try await services.repository.deleteItem(id: milk.id, householdId: hid)
        try await waitUntil { notifications.log.contains("cancel \(milk.id)") }

        // Signing out clears every expiry reminder and the shopping list.
        app.signOut()
        try await waitUntil { notifications.log.last == "keep []" }
        #expect(app.shoppingList.isEmpty && app.items.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
