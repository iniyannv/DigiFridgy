import Foundation
import UserNotifications

/// Local notifications only (no APNs without a paid developer account).
final class LocalNotificationService: NotificationService {
    nonisolated static let runningOutCategory = "RUNNING_OUT"
    nonisolated static let addToListAction = "ADD_TO_LIST"

    private var center: UNUserNotificationCenter { .current() }

    init() {
        let add = UNNotificationAction(identifier: Self.addToListAction, title: "Add to shopping list")
        let category = UNNotificationCategory(identifier: Self.runningOutCategory, actions: [add], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 9 AM the day before expiry. Identifier = item id, so re-scheduling replaces the old one.
    func scheduleExpiryReminder(for item: FridgeItem) {
        cancelExpiryReminder(itemId: item.id)
        guard item.count > 0 else { return }
        let calendar = Calendar.current
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: item.expiresAt) else { return }
        var components = calendar.dateComponents([.year, .month, .day], from: dayBefore)
        components.hour = 9
        guard let fireDate = calendar.date(from: components), fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(item.name) expires tomorrow"
        content.body = item.expiryIsEstimated
            ? "Estimated from its food type. Use it up or check the label."
            : "Use it up before it goes to waste."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
    }

    func cancelExpiryReminder(itemId: String) {
        center.removePendingNotificationRequests(withIdentifiers: [itemId])
    }

    func removeExpiryReminders(except keep: Set<String>) async {
        // Expiry reminders are the only calendar-triggered requests; the rest fire after 1 s.
        let stale = await center.pendingNotificationRequests()
            .filter { $0.trigger is UNCalendarNotificationTrigger && !keep.contains($0.identifier) }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        // Alerts already shown for items that are gone, too.
        let shown = await center.deliveredNotifications()
            .filter { $0.request.trigger is UNCalendarNotificationTrigger && !keep.contains($0.request.identifier) }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: shown)
    }

    func notifyNow(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if id.hasPrefix("runout-") {
            content.categoryIdentifier = Self.runningOutCategory
            content.userInfo = ["itemName": title.replacingOccurrences(of: "You're out of ", with: "")]
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Shows banners while the app is open (important for the live demo) and handles "Add to shopping list".
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == LocalNotificationService.addToListAction,
              let name = response.notification.request.content.userInfo["itemName"] as? String else { return }
        await MainActor.run {
            appState?.addToShoppingList(name: name, barcode: nil)
        }
    }
}
