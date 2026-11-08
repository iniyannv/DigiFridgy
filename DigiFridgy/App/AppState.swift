import Foundation
import Observation
import BackgroundTasks
import os

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var isError: Bool = false
    var actionTitle: String?
    var action: (() -> Void)?
}

/// App-wide session + household state. The single place that mutates household data,
/// so notifications and price/recall bookkeeping stay consistent.
@Observable
final class AppState {
    enum Phase: Equatable {
        case launching, onboarding, householdSetup, ready
    }

    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist (`$(PRODUCT_BUNDLE_IDENTIFIER).refresh`).
    static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "com.iniyann.digifridgy") + ".refresh"
    private static let log = Logger(subsystem: "DigiFridgy", category: "app")

    let services: AppServices
    let notificationDelegate = NotificationDelegate()

    var phase: Phase = .launching
    var user: AuthUser?
    var profile: UserProfile?
    var household: Household?
    var items: [FridgeItem] = []
    var shoppingList: [ShoppingListItem] = []
    /// Questions from the iMessage agent waiting on a YES (open ones only).
    var approvals: [Approval] = []
    var itemsLoaded = false
    var toast: Toast?
    var isRunningChecks = false
    var lastChecksSummary: String?
    /// Last error shown to the user (also kept for Settings / debugging once the toast is gone).
    var lastError: String?
    /// Notification permission was denied: expiry reminders and alerts can't be shown.
    var notificationsDenied = false

    private var itemsTask: Task<Void, Never>?
    private var shoppingTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var checksTask: Task<String, Never>?
    /// A live stream ended with an error; resubscribe when the app becomes active again.
    private var streamsEnded = false
    private var approvalsTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        notificationDelegate.appState = self
    }

    // MARK: Derived

    var householdId: String? { household?.id }
    var userAllergens: Set<Allergen> { profile?.allergenSet ?? [] }
    var sortedItems: [FridgeItem] { items.sorted { $0.expiresAt < $1.expiresAt } }
    var recalledItems: [FridgeItem] { items.filter { $0.recallFlag != nil } }
    var shelfLife: ShelfLifeService { services.shelfLife }

    func item(id: String) -> FridgeItem? { items.first { $0.id == id } }

    func isWatched(_ item: FridgeItem) -> Bool {
        guard let code = item.normalizedBarcode else { return false }
        return profile?.watchlist.contains(code) ?? false
    }

    // MARK: Toasts

    func showError(_ error: any Error) {
        showError(message: error.localizedDescription)
        // Keep the technical reason for the log and Settings → Developer, not the toast.
        if let reason = (error as? LocalizedError)?.failureReason {
            lastError = "\(error.localizedDescription) — \(reason)"
            Self.log.error("\(reason, privacy: .public)")
        }
    }

    func showError(message: String) {
        lastError = message
        Self.log.error("\(message, privacy: .public)")
        toast = Toast(message: message, isError: true)
    }

    func showMessage(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toast = Toast(message: message, actionTitle: actionTitle, action: action)
    }

    // MARK: Session lifecycle

    func bootstrap() async {
        guard let user = services.auth.currentUser else {
            phase = .onboarding
            return
        }
        await didSignIn(user)
    }

    private func didSignIn(_ user: AuthUser) async {
        self.user = user
        do {
            var profile = try await services.repository.profile(uid: user.uid) ?? UserProfile(uid: user.uid)
            if profile.displayName.isEmpty { profile.displayName = user.email?.components(separatedBy: "@").first ?? "Me" }
            self.profile = profile
            // The repository only returns households the caller is a member of.
            if let hid = profile.householdId, let household = try await services.repository.household(id: hid) {
                enterHousehold(household)
            } else {
                phase = .householdSetup
            }
        } catch {
            showError(error)
            phase = .householdSetup
        }
    }

    private func enterHousehold(_ household: Household) {
        self.household = household
        phase = .ready
        startListening(householdId: household.id)
        // Reminders are asked for in context (after the first item is added), not on entry.
        Task {
            let granted = await services.notifications.isAuthorized()
            notificationsDenied = !granted && UserDefaults.standard.bool(forKey: Self.askedNotificationsKey)
            if granted { scheduleReconcile() }
        }
    }

    private static let askedNotificationsKey = "askedNotificationPermission"

    /// First time something lands in the fridge: ask for reminder permission, when the reason is obvious.
    private func requestNotificationsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.askedNotificationsKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedNotificationsKey)
        Task {
            let granted = await services.notifications.requestAuthorization()
            notificationsDenied = !granted
            if granted { scheduleReconcile() }
        }
    }

    private func startListening(householdId: String) {
        itemsTask?.cancel()
        shoppingTask?.cancel()
        itemsLoaded = false
        streamsEnded = false
        itemsTask = Task { [weak self, repository = services.repository] in
            do {
                for try await items in repository.itemsStream(householdId: householdId) {
                    guard let self else { return }
                    self.items = items
                    self.itemsLoaded = true
                    // Roommates' and the bank's changes arrive here too, so reminders follow every change.
                    self.scheduleReconcile()
                }
            } catch is CancellationError {
            } catch {
                self?.itemsLoaded = true
                self?.streamsEnded = true
                self?.showError(message: "Your fridge stopped syncing. Leave the app and come back to reconnect.")
                Self.log.error("items stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        approvalsTask?.cancel()
        approvalsTask = Task { [weak self, repository = services.repository] in
            for await list in repository.approvalsStream(householdId: householdId) {
                self?.approvals = list.filter(\.isOpen)
            }
        }
        shoppingTask = Task { [weak self, repository = services.repository] in
            do {
                for try await list in repository.shoppingStream(householdId: householdId) {
                    self?.shoppingList = list
                }
            } catch is CancellationError {
            } catch {
                self?.streamsEnded = true
                self?.showError(message: "The shopping list stopped syncing. Leave the app and come back to reconnect.")
                Self.log.error("shopping stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Scene became active: resubscribe if a live stream ended, and refresh notification permission.
    func didBecomeActive() {
        guard phase == .ready, let hid = householdId else { return }
        if streamsEnded {
            Self.log.info("resubscribing to household streams")
            startListening(householdId: hid)
        }
        Task {
            let granted = await services.notifications.isAuthorized()
            // Not asked yet isn't "denied": the prompt comes after the first item is added.
            notificationsDenied = !granted && UserDefaults.standard.bool(forKey: Self.askedNotificationsKey)
            scheduleReconcile()
        }
    }

    /// Coalesces bursts of item changes into one reminder reconcile.
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.householdId != nil else { return }
            await self.services.notifications.reconcile(items: self.items)
        }
    }

    private func clearReminders() {
        reconcileTask?.cancel()
        reconcileTask = nil
        services.notifications.removeAllReminders()
    }

    func signInAnonymously() async {
        do { await didSignIn(try await services.auth.signInAnonymously()) } catch { showError(error) }
    }

    func signIn(email: String, password: String, createAccount: Bool) async {
        do {
            let user = createAccount
                ? try await services.auth.signUp(email: email, password: password)
                : try await services.auth.signIn(email: email, password: password)
            await didSignIn(user)
        } catch {
            showError(error)
        }
    }

    func linkEmail(email: String, password: String) async -> Bool {
        do {
            user = try await services.auth.linkEmail(email: email, password: password)
            showMessage("Account saved — you can now sign in with \(email).")
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func signOut() {
        do { try services.auth.signOut() } catch { showError(error) }
        itemsTask?.cancel()
        shoppingTask?.cancel()
        clearReminders()
        approvalsTask?.cancel()
        approvals = []
        user = nil
        profile = nil
        household = nil
        items = []
        shoppingList = []
        phase = .onboarding
    }

    func createHousehold(name: String) async {
        guard let user else { return }
        do {
            let household = try await services.repository.createHousehold(
                name: name.isEmpty ? "Our Fridge" : name, ownerUid: user.uid)
            try await updateProfile { $0.householdId = household.id }
            enterHousehold(household)
            if services.isMock, (try? await services.repository.fetchItems(householdId: household.id))?.isEmpty ?? true {
                await seedDemoHousehold(silently: true)
            }
        } catch {
            showError(error)
        }
    }

    func joinHousehold(code: String) async {
        guard let user else { return }
        do {
            let household = try await services.repository.joinHousehold(code: code, uid: user.uid)
            try await updateProfile { $0.householdId = household.id }
            enterHousehold(household)
            showMessage("Joined \(household.name)")
        } catch {
            showError(error)
        }
    }

    func leaveHousehold() async {
        guard let user, let hid = householdId else { return }
        do {
            try await services.repository.leaveHousehold(id: hid, uid: user.uid)
            try await updateProfile { $0.householdId = nil }
            itemsTask?.cancel()
            shoppingTask?.cancel()
            clearReminders()
            approvalsTask?.cancel()
            approvals = []
            household = nil
            items = []
            shoppingList = []
            phase = .householdSetup
        } catch {
            showError(error)
        }
    }

    // MARK: Profile

    func updateProfile(_ change: (inout UserProfile) -> Void) async throws {
        guard let user else { return }
        var updated = profile ?? UserProfile(uid: user.uid)
        change(&updated)
        profile = updated
        try await services.repository.saveProfile(updated)
    }

    func setAllergen(_ allergen: Allergen, enabled: Bool) {
        Task {
            do {
                try await updateProfile { p in
                    var set = Set(p.allergens)
                    if enabled { set.insert(allergen.rawValue) } else { set.remove(allergen.rawValue) }
                    p.allergens = Allergen.allCases.map(\.rawValue).filter(set.contains)
                }
            } catch { showError(error) }
        }
    }

    func setSearchRadius(_ miles: Double) {
        Task {
            do { try await updateProfile { $0.searchRadiusMiles = miles } } catch { showError(error) }
        }
    }

    func toggleWatch(_ item: FridgeItem) {
        guard let code = item.normalizedBarcode else { return }
        Task {
            do {
                try await updateProfile { p in
                    if p.watchlist.contains(code) { p.watchlist.removeAll { $0 == code } } else { p.watchlist.append(code) }
                }
            } catch { showError(error) }
        }
    }

    // MARK: Item creation

    func lookupProduct(barcode: String) async throws -> ProductInfo? {
        try await services.products.lookup(barcode: Barcode.normalize(barcode))
    }

    /// Existing item with the same barcode, if any.
    func existingItem(barcode: String) -> FridgeItem? {
        let code = Barcode.normalize(barcode)
        return items.first { $0.normalizedBarcode == code }
    }

    /// An item a re-scan of this barcode can simply add one to: same product, no recall flag, and an estimated
    /// expiry equal to what a new unit would get today. Otherwise the scan becomes a new unit with its own estimate.
    func bumpableItem(barcode: String) -> FridgeItem? {
        let code = Barcode.normalize(barcode)
        return items.first { item in
            item.normalizedBarcode == code && item.recallFlag == nil && item.expiryIsEstimated
                && Calendar.current.isDate(item.expiresAt,
                                           inSameDayAs: shelfLife.estimatedExpiry(categoryID: item.category))
        }
    }

    func draft(from product: ProductInfo) -> FridgeItem {
        var category = shelfLife.categoryID(forOFFTags: product.categoryTags)
        if category == ShelfLifeService.unknownCategoryID { category = shelfLife.categoryID(forName: product.name) }
        let allergens = product.allergenTags.isEmpty
            ? Allergen.implied(byCategory: category).map(\.rawValue) : product.allergenTags
        let item = FridgeItem(
            barcode: product.barcode.map(Barcode.normalize),
            name: product.name.isEmpty ? "Unknown product" : product.name,
            brand: product.brand, category: category, imageURL: product.imageURL,
            addedBy: user?.uid ?? "", expiresAt: shelfLife.estimatedExpiry(categoryID: category),
            source: .barcode, nutrition: product.nutrition, nutriScore: product.nutriScore, allergens: allergens
        )
        return applyingOverride(to: item)
    }

    /// The scan with the AI's name and category (see `BankStore.describeProduct`). The expiry estimate and
    /// the allergens implied by the old category follow the new category; the user can still edit everything.
    func applyingAIGuess(_ item: FridgeItem, name: String?, category: String) -> FridgeItem {
        guard category == ShelfLifeService.unknownCategoryID || shelfLife.category(id: category) != nil else { return item }
        var out = item
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { out.name = name }
        if category != item.category {
            if item.allergens == Allergen.implied(byCategory: item.category).map(\.rawValue) {
                out.allergens = Allergen.implied(byCategory: category).map(\.rawValue)
            }
            out.category = category
            out.expiresAt = shelfLife.estimatedExpiry(categoryID: category)
        }
        return out
    }

    /// Scan result for a barcode: the looked-up product with the user's saved corrections applied,
    /// or just the corrections when Open Food Facts doesn't know the barcode. Nil = unknown product.
    func draftForScan(barcode: String) async throws -> FridgeItem? {
        let code = Barcode.normalize(barcode)
        let saved = services.productOverrides.override(forBarcode: code)
        let product: ProductInfo?
        do {
            product = try await lookupProduct(barcode: code)
        } catch {
            // Offline / API error: the saved corrections are still enough to add the item.
            guard saved != nil else { throw error }
            product = nil
        }
        if let product, !product.name.isEmpty { return draft(from: product) }
        guard saved != nil else { return nil }
        return applyingOverride(to: FridgeItem(
            barcode: code, name: "", category: ShelfLifeService.unknownCategoryID, imageURL: product?.imageURL,
            addedBy: user?.uid ?? "", expiresAt: .now, source: .barcode))
    }

    /// Whether the user has saved corrections for this barcode.
    func hasSavedCorrections(barcode: String?) -> Bool {
        barcode.flatMap(services.productOverrides.override(forBarcode:)) != nil
    }

    /// Applies saved corrections (name, brand, category, nutrition) and re-derives what depends on the category.
    private func applyingOverride(to item: FridgeItem) -> FridgeItem {
        guard let code = item.normalizedBarcode,
              let saved = services.productOverrides.override(forBarcode: code) else { return item }
        var updated = item
        saved.apply(to: &updated)
        if updated.category != item.category || updated.expiresAt <= .now {
            updated.expiresAt = shelfLife.estimatedExpiry(categoryID: updated.category)
            updated.expiryIsEstimated = true
        }
        if item.allergens.isEmpty || (updated.category != item.category && item.allergens == Allergen.implied(byCategory: item.category).map(\.rawValue)) {
            updated.allergens = Allergen.implied(byCategory: updated.category).map(\.rawValue)
        }
        return updated
    }

    /// Saves a newly scanned item. When the user changed the name, brand, category or nutrition from what
    /// the lookup returned (or already had corrections for this barcode), remembers them for future scans.
    /// `original == nil` means the user typed the product in themselves (unknown barcode): always remembered.
    func saveScanned(_ item: FridgeItem, original: FridgeItem?) async -> Bool {
        let edited = original.map { original in
            item.name != original.name || item.brand != original.brand
                || item.category != original.category || item.nutrition != original.nutrition
        } ?? true
        if item.barcode != nil, edited || hasSavedCorrections(barcode: item.barcode) {
            rememberCorrections(item)
        }
        return await save(item)
    }

    /// Edits an item already in the fridge. For barcode items the change is remembered for future scans.
    func updateDetails(_ item: FridgeItem, name: String, brand: String?, category: String, nutrition: Nutrition?) async -> Bool {
        var updated = item
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.brand = brand.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if updated.category != category {
            if updated.allergens == Allergen.implied(byCategory: updated.category).map(\.rawValue) {
                updated.allergens = Allergen.implied(byCategory: category).map(\.rawValue)
            }
            updated.category = category
            if updated.expiryIsEstimated {
                updated.expiresAt = shelfLife.estimatedExpiry(categoryID: category, from: updated.addedAt)
            }
        }
        updated.nutrition = nutrition.flatMap { $0.isEmpty && $0.servingSize == nil ? nil : $0 }
        guard await save(updated) else { return false }
        if updated.barcode != nil { rememberCorrections(updated) }
        return true
    }

    private func rememberCorrections(_ item: FridgeItem) {
        if let error = services.productOverrides.remember(item) {
            showError(message: "Couldn't save your corrections for next time: \(error.localizedDescription)")
        }
    }

    /// For barcodes Open Food Facts doesn't know: user-typed name + CalorieNinjas nutrition.
    func draft(name: String, barcode: String?) async -> FridgeItem {
        let category = shelfLife.categoryID(forName: name)
        let nutrition = try? await services.products.nutrition(forName: name)
        return FridgeItem(
            barcode: barcode.map(Barcode.normalize), name: name, category: category,
            addedBy: user?.uid ?? "", expiresAt: shelfLife.estimatedExpiry(categoryID: category),
            source: .barcode, nutrition: nutrition ?? nil,
            allergens: Allergen.implied(byCategory: category).map(\.rawValue)
        )
    }

    func save(_ item: FridgeItem) async -> Bool {
        guard let hid = householdId else { showError(HouseholdError.noHousehold); return false }
        do {
            try await services.repository.saveItem(item, householdId: hid)
            upsertLocal(item)
            scheduleReconcile()
            requestNotificationsIfNeeded()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func saveReceiptItems(_ newItems: [FridgeItem]) async -> Bool {
        guard let hid = householdId else { showError(HouseholdError.noHousehold); return false }
        do {
            try await services.repository.saveItems(newItems, householdId: hid)
            newItems.forEach(upsertLocal)
            scheduleReconcile()
            requestNotificationsIfNeeded()
            showMessage("Added \(newItems.count) item\(newItems.count == 1 ? "" : "s") from your receipt")
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func upsertLocal(_ item: FridgeItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item } else { items.append(item) }
    }

    // MARK: Item edits

    func adjustCount(_ item: FridgeItem, by delta: Int) async {
        guard let hid = householdId else { return }
        // The view's copy can be stale (a roommate's change may have arrived since): start from the current one.
        let current = self.item(id: item.id) ?? item
        let base = current.count
        let newCount = max(base + delta, 0)
        if delta < 0 {
            // Using food up is recorded as yours, so roommates can split what each of them ate.
            do {
                try await services.repository.useItem(id: current.id, qty: min(-delta, base), name: current.name,
                                                       remaining: newCount, householdId: hid)
            } catch {
                showError(error)
                return
            }
            if newCount <= 0 {
                removedLocally(current, ranOut: true)
            } else {
                applyCount(itemId: current.id, from: base, to: newCount)
            }
            return
        }
        do {
            try await services.repository.incrementCount(itemId: current.id, by: delta, householdId: hid)
            applyCount(itemId: current.id, from: base, to: newCount)
        } catch {
            showError(error)
        }
    }

    /// After an await: only apply our change if the live stream hasn't already delivered a newer count.
    private func applyCount(itemId: String, from base: Int, to newCount: Int) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }), items[idx].count == base else { return }
        items[idx].count = newCount
    }

    func delete(_ item: FridgeItem, ranOut: Bool = false, undoable: Bool = false) async {
        guard let hid = householdId else { return }
        do {
            try await services.repository.deleteItem(id: item.id, householdId: hid)
            removedLocally(item, ranOut: ranOut)
            if undoable && !ranOut {
                showMessage("Deleted \(item.name)", actionTitle: "Undo") { [weak self] in
                    Task { _ = await self?.save(item) }
                }
            }
        } catch {
            showError(error)
        }
    }

    /// Deletes several fridge items at once (multi-select), with one Undo for all of them.
    func delete(_ selected: [FridgeItem]) async {
        guard let hid = householdId, !selected.isEmpty else { return }
        var deleted: [FridgeItem] = []
        var failure: (any Error)?
        for item in selected {
            do {
                try await services.repository.deleteItem(id: item.id, householdId: hid)
                removedLocally(item, ranOut: false)
                deleted.append(item)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure, deleted.isEmpty { showError(failure); return }
        let message = deleted.count == 1 ? "Deleted \(deleted[0].name)" : "Deleted \(deleted.count) items"
        showMessage(failure == nil ? message : message + " (some couldn't be deleted)", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.services.repository.saveItems(deleted, householdId: hid)
                    deleted.forEach(self.upsertLocal)
                    self.scheduleReconcile()
                } catch { self.showError(error) }
            }
        }
    }

    private func removedLocally(_ item: FridgeItem, ranOut: Bool) {
        items.removeAll { $0.id == item.id }
        scheduleReconcile()
        if ranOut {
            services.notifications.notifyNow(id: "runout-\(item.id)", title: "You're out of \(item.name)",
                                             body: "Add it to the shopping list?")
            showMessage("Out of \(item.name)", actionTitle: "Add to list") { [weak self] in
                self?.addToShoppingList(name: item.name, barcode: item.barcode)
            }
        }
    }

    func setExpiry(_ item: FridgeItem, to date: Date) async {
        var updated = self.item(id: item.id) ?? item
        updated.expiresAt = Calendar.current.startOfDay(for: date)
        updated.expiryIsEstimated = false
        _ = await save(updated)
    }

    /// "Not my product": clears the recall flag and never flags this item for that recall again.
    func dismissRecall(_ item: FridgeItem) async {
        var updated = self.item(id: item.id) ?? item
        guard let flag = updated.recallFlag else { return }
        updated.recallFlag = nil
        if !updated.dismissedRecallIDs.contains(flag.recallId) { updated.dismissedRecallIDs.append(flag.recallId) }
        if await save(updated) {
            services.notifications.removeNotifications(ids: ["recall-\(item.id)"])
            showMessage("Recall dismissed for \(updated.name)", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                var restored = self.item(id: item.id) ?? updated
                restored.recallFlag = flag
                restored.dismissedRecallIDs.removeAll { $0 == flag.recallId }
                Task { _ = await self.save(restored) }
            }
        }
    }

    // MARK: Shopping list

    func addToShoppingList(name: String, barcode: String?) {
        guard let hid = householdId else { return }
        guard !shoppingList.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.done }) else {
            showMessage("\(name) is already on the list")
            return
        }
        let entry = ShoppingListItem(name: name, barcode: barcode)
        Task {
            do {
                try await services.repository.saveShoppingItem(entry, householdId: hid)
                showMessage("Added \(name) to the shopping list")
            } catch { showError(error) }
        }
    }

    /// Adds several items at once (a recipe's missing ingredients), skipping ones already on the list.
    func addToShoppingList(names: [String]) {
        guard let hid = householdId else { return }
        let onList = Set(shoppingList.filter { !$0.done }.map { $0.name.lowercased() })
        var seen = Set<String>()
        let new = names.filter { !onList.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        guard !new.isEmpty else {
            showMessage(names.count == 1 ? "\(names[0]) is already on the list" : "Those are already on the list")
            return
        }
        Task {
            do {
                for name in new {
                    try await services.repository.saveShoppingItem(ShoppingListItem(name: name, barcode: nil), householdId: hid)
                }
                showMessage(new.count == 1 ? "Added \(new[0]) to the shopping list"
                                           : "Added \(new.count) items to the shopping list")
            } catch { showError(error) }
        }
    }

    /// "I'll get it": the household (and its iMessage group) sees who's buying it. Tap again to let it go.
    func toggleClaim(_ entry: ShoppingListItem) {
        guard let hid = householdId else { return }
        let me = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        let name = me.isEmpty || me == "Me" ? "Someone" : me
        var updated = entry
        updated.claimedBy = entry.claimedBy == name ? nil : name
        Task {
            do { try await services.repository.saveShoppingItem(updated, householdId: hid) } catch { showError(error) }
        }
    }

    func answer(_ approval: Approval, yes: Bool) {
        approvals.removeAll { $0.id == approval.id }
        Task {
            do {
                try await services.repository.decideApproval(id: approval.id, approve: yes)
                showMessage(yes ? "Done. The answer went to the household chat too." : "Got it. Answered no.")
            } catch { showError(error) }
        }
    }

    func toggleShoppingItem(_ entry: ShoppingListItem) {
        guard let hid = householdId else { return }
        var updated = entry
        updated.done.toggle()
        Task {
            do { try await services.repository.saveShoppingItem(updated, householdId: hid) } catch { showError(error) }
        }
    }

    func deleteShoppingItem(_ entry: ShoppingListItem) {
        guard let hid = householdId else { return }
        Task {
            do { try await services.repository.deleteShoppingItem(id: entry.id, householdId: hid) } catch { showError(error) }
        }
    }

    /// Marks several shopping-list entries bought (or not bought).
    func setShoppingItems(_ entries: [ShoppingListItem], done: Bool) {
        guard let hid = householdId else { return }
        let changed = entries.filter { $0.done != done }
        guard !changed.isEmpty else { return }
        Task {
            do {
                for entry in changed {
                    var updated = entry
                    updated.done = done
                    try await services.repository.saveShoppingItem(updated, householdId: hid)
                }
                showMessage(done ? "Marked \(changed.count == 1 ? changed[0].name : "\(changed.count) items") bought"
                                 : "Moved \(changed.count == 1 ? changed[0].name : "\(changed.count) items") back to the list")
            } catch { showError(error) }
        }
    }

    /// "I'll get them" for several entries at once.
    func claimShoppingItems(_ entries: [ShoppingListItem]) {
        guard let hid = householdId else { return }
        let me = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        let name = me.isEmpty || me == "Me" ? "Someone" : me
        let open = entries.filter { !$0.done && $0.claimedBy != name }
        guard !open.isEmpty else { return }
        Task {
            do {
                for entry in open {
                    var updated = entry
                    updated.claimedBy = name
                    try await services.repository.saveShoppingItem(updated, householdId: hid)
                }
                showMessage(open.count == 1 ? "You're getting \(open[0].name)" : "You're getting \(open.count) items")
            } catch { showError(error) }
        }
    }

    /// Deletes several shopping-list entries, with one Undo.
    func deleteShoppingItems(_ entries: [ShoppingListItem]) {
        guard let hid = householdId, !entries.isEmpty else { return }
        Task {
            do {
                for entry in entries {
                    try await services.repository.deleteShoppingItem(id: entry.id, householdId: hid)
                }
                showMessage(entries.count == 1 ? "Deleted \(entries[0].name)" : "Deleted \(entries.count) items",
                            actionTitle: "Undo") { [weak self] in
                    guard let self else { return }
                    Task {
                        do {
                            for entry in entries {
                                try await self.services.repository.saveShoppingItem(entry, householdId: hid)
                            }
                        } catch { self.showError(error) }
                    }
                }
            } catch { showError(error) }
        }
    }

    // MARK: Checks (recalls + watched prices) — shared by BGAppRefreshTask and "Run checks now"

    /// Single-flight: a second caller (background task + "Run checks now") waits for the run in progress.
    @discardableResult
    func runChecks() async -> String {
        if let running = checksTask { return await running.value }
        let task = Task { await performChecks() }
        checksTask = task
        let summary = await task.value
        checksTask = nil
        return summary
    }

    private func performChecks() async -> String {
        guard let hid = householdId else { return "No household" }
        isRunningChecks = true
        defer { isRunningChecks = false }
        var notes: [String] = []

        // Recalls
        do {
            let recalls = try await services.recalls.recentRecalls(days: 90)
            var flagged = 0
            for id in items.map(\.id) {
                // Re-read after every await: the item may have changed or gone meanwhile.
                guard let item = self.item(id: id), item.recallFlag == nil,
                      let hit = services.recallMatcher.match(item, in: recalls) else { continue }
                var updated = item
                updated.recallFlag = hit.flag
                try await services.repository.saveItem(updated, householdId: hid)
                // Apply only the flag to whatever the item looks like now.
                if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].recallFlag = hit.flag }
                flagged += 1
                services.notifications.notifyNow(
                    id: "recall-\(id)",
                    title: hit.confidence == .possible ? "Possible recall: \(item.name)" : "Recall: \(item.name)",
                    body: hit.confidence == .possible ? "Check the brand. \(hit.recall.reason)" : hit.recall.reason)
            }
            notes.append("\(recalls.count) FDA recalls checked, \(flagged) new match\(flagged == 1 ? "" : "es")")
        } catch {
            notes.append("Recalls failed: \(error.localizedDescription)")
        }

        // Watched prices
        let drops = await checkWatchedPrices(householdId: hid)
        notes.append(drops)

        let summary = notes.joined(separator: " · ")
        lastChecksSummary = summary
        return summary
    }

    /// Price-drop alerts compare live Kroger prices with earlier live prices only. Sample prices are never
    /// alerted on (they aren't real), and history records which kind each price was.
    private func checkWatchedPrices(householdId hid: String) async -> String {
        let watchlist = profile?.watchlist ?? []
        guard !watchlist.isEmpty else { return "No watched prices" }
        guard services.kroger.isLive else { return "Price alerts need live Kroger prices (only sample prices here)" }
        let coordinate = await currentCoordinate()
        let radius = profile?.searchRadiusMiles ?? 10
        let store: Store
        do {
            guard let nearest = try await services.kroger.locations(near: coordinate, radiusMiles: radius, limit: 1).first else {
                return "No Kroger store in range"
            }
            store = nearest
        } catch {
            return "Kroger failed: \(error.localizedDescription)"
        }
        var drops = 0
        var failures = 0
        for upc in watchlist {
            let item = items.first { $0.normalizedBarcode == upc }
            let name = item?.name ?? upc
            let price: Double
            do {
                guard let live = try await services.kroger.price(upc: upc, term: name, locationId: store.id) else { continue }
                price = live.effective
            } catch {
                failures += 1
                continue
            }
            let previous: PriceHistory?
            do {
                previous = try await services.repository.priceHistory(upc: upc, householdId: hid)
            } catch {
                failures += 1
                previous = nil
            }
            if let previous, previous.isLive, price < previous.lastPrice - 0.001 {
                drops += 1
                notifyPriceDrop(name: name, price: price, previous: previous.lastPrice, store: store.name)
            }
            do {
                try await services.repository.savePriceHistory(
                    PriceHistory(upc: upc, lastPrice: price, lastStoreId: store.id, checkedAt: .now), householdId: hid)
            } catch {
                failures += 1
            }
        }
        var summary = "\(watchlist.count) watched price\(watchlist.count == 1 ? "" : "s"), \(drops) drop\(drops == 1 ? "" : "s")"
        if failures > 0 { summary += ", \(failures) failed" }
        return summary
    }

    private func notifyPriceDrop(name: String, price: Double, previous: Double, store: String, demo: Bool = false) {
        services.notifications.notifyNow(
            id: "price-\(name)-\(Int(Date.now.timeIntervalSince1970))",
            title: "\(demo ? "Demo: price drop" : "Price drop"): \(name)",
            body: "Now \(price.formatted(.currency(code: "USD"))) at \(store) (was \(previous.formatted(.currency(code: "USD"))))."
                + (demo ? " Sample prices, not a real offer." : ""))
    }

    /// Called by the BGAppRefreshTask. The app may be cold-launched in the background.
    func runBackgroundChecks() async {
        if phase == .launching { await bootstrap() }
        guard let hid = householdId else { return }
        if !itemsLoaded, let fetched = try? await services.repository.fetchItems(householdId: hid) {
            items = fetched
        }
        await runChecks()
        await services.notifications.reconcile(items: items)
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(4 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the Simulator (unsupported); on a device it means the identifier isn't permitted.
            Self.log.error("background refresh not scheduled (\(Self.refreshTaskID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Location

    private static let lastCoordinateKey = "lastCoordinate"

    func currentCoordinate() async -> Coordinate {
        if let coordinate = await services.location.currentCoordinate() {
            UserDefaults.standard.set([coordinate.latitude, coordinate.longitude], forKey: Self.lastCoordinateKey)
            return coordinate
        }
        if let saved = UserDefaults.standard.array(forKey: Self.lastCoordinateKey) as? [Double], saved.count == 2 {
            return Coordinate(latitude: saved[0], longitude: saved[1])
        }
        return .demoFallback
    }

    // MARK: Demo helpers

    func seedDemoHousehold(silently: Bool = false) async {
        guard let hid = householdId, let uid = user?.uid else { return }
        let seed = DemoData.householdItems(uid: uid)
        do {
            try await services.repository.saveItems(seed, householdId: hid)
            seed.forEach(upsertLocal)
            scheduleReconcile()
            if profile?.allergens.isEmpty ?? true {
                try await updateProfile { $0.allergens = [Allergen.sesame.rawValue] }
            }
            if !silently { showMessage("Added \(seed.count) demo items") }
        } catch {
            showError(error)
        }
    }

    /// Fills the fridge and shopping list with real products (real UPCs, names and photos from Open Food Facts),
    /// so barcode lookups, store prices and recalls run against real codes.
    func seedBarcodeDemo() async {
        guard let hid = householdId, let uid = user?.uid else { return }
        let seed = BarcodeDemoData.householdItems(uid: uid)
        do {
            try await services.repository.saveItems(seed, householdId: hid)
            seed.forEach(upsertLocal)
            scheduleReconcile()
            let onList = Set(shoppingList.compactMap(\.barcode))
            for entry in BarcodeDemoData.shoppingItems() where !onList.contains(entry.barcode ?? "") {
                try await services.repository.saveShoppingItem(entry, householdId: hid)
            }
            showMessage("Added \(seed.count) real products and \(BarcodeDemoData.shopping.count) list items")
        } catch {
            showError(error)
        }
    }

    /// Flags the most "recallable" fridge item with a fake recall, then notifies — for the live demo.
    func simulateRecall() async {
        guard let hid = householdId else { return }
        let candidates = sortedItems.filter { $0.recallFlag == nil }
        guard let target = candidates.first(where: { $0.barcode != nil }) ?? candidates.first else {
            showMessage("Add an item first")
            return
        }
        let recall = Recall(
            id: "SIM-\(Int(Date.now.timeIntervalSince1970))",
            reason: "Simulated recall: possible Listeria monocytogenes contamination. Do not consume; return for a refund.",
            productDescription: "\(target.brand ?? "") \(target.name) UPC \(target.barcode ?? "n/a")",
            codeInfo: target.barcode ?? "", firm: target.brand ?? "Demo Foods Inc.", date: .now,
            classification: "Class I",
            url: "https://www.fda.gov/safety/recalls-market-withdrawals-safety-alerts")
        // Run it through the real matcher so the demo exercises the same path as live data
        // (a brandless item without a barcode comes out as a possible recall).
        let flag = services.recallMatcher.match(target, in: [recall])?.flag ?? recall.asFlag
        var updated = target
        updated.recallFlag = flag
        do {
            try await services.repository.saveItem(updated, householdId: hid)
            upsertLocal(updated)
            services.notifications.notifyNow(id: "recall-\(target.id)",
                                             title: "\(flag.isPossible ? "Possible recall" : "Recall"): \(target.name)",
                                             body: recall.reason)
            showMessage("Simulated recall for \(target.name)")
        } catch {
            showError(error)
        }
    }

    /// Records a higher "last price" for each watched item, so the next check reports a drop.
    func simulatePriceDrop() async {
        guard let hid = householdId else { return }
        let watched = items.filter(isWatched)
        guard let item = watched.first ?? items.first(where: { $0.barcode != nil }) else {
            showMessage("Scan a barcode item first")
            return
        }
        if !isWatched(item) { toggleWatch(item) }
        let reference = services.mockPrices.referencePrice(categoryID: item.category)
        let high = services.mockPrices.price(upc: item.barcode, name: item.name, chain: "Kroger", referencePrice: reference) + 1.0
        notifyPriceDrop(name: item.name, price: high - 1.0, previous: high, store: "Kroger", demo: true)
        do {
            // Stored as a sample price, so a later live check never compares against it.
            try await services.repository.savePriceHistory(
                PriceHistory(upc: item.normalizedBarcode ?? item.id, lastPrice: high,
                             lastStoreId: PriceHistory.samplePrefix + "sim", checkedAt: .now),
                householdId: hid)
        } catch {
            showError(error)
        }
        showMessage("Simulated price drop for \(item.name) (demo)")
    }

    func testExpiryNotification() {
        guard let item = sortedItems.first else { showMessage("Add an item first"); return }
        services.notifications.notifyNow(id: "expiry-test-\(item.id)", title: "\(item.name): \(item.expiryLabel())",
                                         body: "Use it up before it goes to waste.")
    }
}

extension KrogerPrice {
    nonisolated var effective: Double { promo.map { min($0, regular) } ?? regular }
}
