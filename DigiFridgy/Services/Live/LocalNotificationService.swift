import Foundation
import UserNotifications
import os

/// One expiry reminder as it should be (or is) scheduled.
nonisolated struct ReminderSpec: Hashable, Sendable {
    var fireDate: Date
    var title: String
    var body: String
    /// Fires "as soon as sensible" (the usual 9 AM the day before had already passed when it was planned).
    /// Re-planning moves such a time forward, so an already-pending one is kept rather than replaced.
    var isASAP: Bool
}

/// Pure planning for expiry reminders, so `reconcile` is testable without UserNotifications.
nonisolated enum ReminderPlanner {
    /// Reminder request identifiers are `expiry.<item id>`.
    static let prefix = "expiry."
    static let reminderHour = 9

    static func identifier(for itemId: String) -> String { prefix + itemId }

    /// 9 AM the day before expiry; when that has passed but the item hasn't expired yet, now + 1 h
    /// (still before the end of the expiry day). Nil = no reminder (expired, used up, or too late).
    static func spec(for item: FridgeItem, now: Date = .now, calendar: Calendar = .current) -> ReminderSpec? {
        guard item.count > 0 else { return nil }
        let expiryDay = calendar.startOfDay(for: item.expiresAt)
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: expiryDay),
              let preferred = calendar.date(bySettingHour: reminderHour, minute: 0, second: 0, of: dayBefore),
              let endOfExpiryDay = calendar.date(byAdding: .day, value: 1, to: expiryDay) else { return nil }
        let fireDate: Date
        let asap: Bool
        if preferred > now {
            fireDate = preferred
            asap = false
        } else {
            let soon = now.addingTimeInterval(3600)
            guard soon < endOfExpiryDay else { return nil }
            fireDate = soon
            asap = true
        }
        return ReminderSpec(
            fireDate: fireDate,
            title: "\(item.name): \(item.expiryLabel(now: fireDate, calendar: calendar))",
            body: item.expiryIsEstimated
                ? "Estimated from its food type. Use it up or check the label."
                : "Use it up before it goes to waste.",
            isASAP: asap)
    }

    /// What every item's reminder should be, keyed by request identifier.
    static func desired(for items: [FridgeItem], now: Date = .now, calendar: Calendar = .current) -> [String: ReminderSpec] {
        var result: [String: ReminderSpec] = [:]
        for item in items {
            if let spec = spec(for: item, now: now, calendar: calendar) { result[identifier(for: item.id)] = spec }
        }
        return result
    }

    /// Requests to add (or replace) and identifiers to remove, given what is pending now.
    /// `pending` holds only reminder requests (other notifications are never touched).
    static func diff(pending: [String: ReminderSpec], desired: [String: ReminderSpec], now: Date = .now)
        -> (add: [String: ReminderSpec], remove: Set<String>) {
        var add: [String: ReminderSpec] = [:]
        var remove = Set(pending.keys).subtracting(desired.keys)
        for (id, want) in desired {
            guard let have = pending[id] else { add[id] = want; continue }
            if have == want { continue }
            // An "as soon as sensible" reminder already pending in the future stays put.
            if want.isASAP, have.fireDate > now, have.fireDate <= want.fireDate,
               have.title == want.title, have.body == want.body {
                continue
            }
            remove.insert(id)
            add[id] = want
        }
        return (add, remove)
    }
}

/// Local notifications only (no APNs without a paid developer account).
final class LocalNotificationService: NotificationService {
    nonisolated static let runningOutCategory = "RUNNING_OUT"
    nonisolated static let addToListAction = "ADD_TO_LIST"
    nonisolated private static let log = Logger(subsystem: "DigiFridgy", category: "notifications")
    private static let asapKey = "asap"

    private var center: UNUserNotificationCenter { .current() }

    init() {
        let add = UNNotificationAction(identifier: Self.addToListAction, title: "Add to shopping list")
        let category = UNNotificationCategory(identifier: Self.runningOutCategory, actions: [add], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Makes the pending expiry reminders match `items`: adds new ones, replaces changed ones and removes
    /// reminders for items that are gone (deleted here, by a roommate, or by the bank backend).
    func reconcile(items: [FridgeItem]) async {
        let requests = await center.pendingNotificationRequests()
        var pending: [String: ReminderSpec] = [:]
        var legacy: [String] = []
        for request in requests {
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { continue }
            guard request.identifier.hasPrefix(ReminderPlanner.prefix) else {
                // Builds before reconcile used the bare item id; replace those.
                legacy.append(request.identifier)
                continue
            }
            guard let fire = trigger.nextTriggerDate() else { continue }
            pending[request.identifier] = ReminderSpec(
                fireDate: fire, title: request.content.title, body: request.content.body,
                isASAP: request.content.userInfo[Self.asapKey] as? Bool ?? false)
        }
        let now = Date.now
        let (add, remove) = ReminderPlanner.diff(pending: pending, desired: ReminderPlanner.desired(for: items, now: now), now: now)
        let stale = Array(remove) + legacy
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
            // Alerts already shown for items that are gone, too (used up by a roommate, say).
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
        let calendar = Calendar.current
        for (id, spec) in add {
            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            content.userInfo = [Self.asapKey: spec.isASAP]
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: spec.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                Self.log.error("couldn't schedule reminder: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !add.isEmpty || !stale.isEmpty {
            Self.log.info("reminders: \(add.count) scheduled, \(stale.count) removed, \(items.count) items")
        }
    }

    /// Sign-out / leaving the household: the next user must not inherit this fridge's reminders.
    func removeAllReminders() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func removeNotifications(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
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
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
            if let error { Self.log.error("couldn't post \(id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
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
