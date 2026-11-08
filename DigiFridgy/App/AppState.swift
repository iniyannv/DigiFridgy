import Foundation
import Observation
import BackgroundTasks

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

    static let refreshTaskID = "com.iniyann.digifridgy.refresh"

    let services: AppServices
    let notificationDelegate = NotificationDelegate()

    var phase: Phase = .launching
    var user: AuthUser?
    var profile: UserProfile?
    var household: Household?
    var items: [FridgeItem] = []
    var shoppingList: [ShoppingListItem] = []
    var itemsLoaded = false
    var toast: Toast?
    var isRunningChecks = false
    var lastChecksSummary: String?

    private var itemsTask: Task<Void, Never>?
    private var shoppingTask: Task<Void, Never>?

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
        toast = Toast(message: error.localizedDescription, isError: true)
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
        Task {
            if await services.notifications.requestAuthorization() {
                items.forEach(services.notifications.scheduleExpiryReminder)
            }
        }
    }

    private func startListening(householdId: String) {
        itemsTask?.cancel()
        shoppingTask?.cancel()
        itemsLoaded = false
        itemsTask = Task { [weak self, repository = services.repository] in
            do {
                for try await items in repository.itemsStream(householdId: householdId) {
                    self?.items = items
                    self?.itemsLoaded = true
                }
            } catch {
                self?.itemsLoaded = true
                self?.showError(error)
            }
        }
        shoppingTask = Task { [weak self, repository = services.repository] in
            do {
                for try await list in repository.shoppingStream(householdId: householdId) {
                    self?.shoppingList = list
                }
            } catch {
                // Shopping list is secondary; the items stream already surfaces permission errors.
            }
        }
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
            household = nil
            items = []
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

    /// Existing item with the same barcode, if any (scanning it again bumps its count).
    func existingItem(barcode: String) -> FridgeItem? {
        let code = Barcode.normalize(barcode)
        return items.first { $0.normalizedBarcode == code }
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
            services.productOverrides.remember(item)
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
        if updated.barcode != nil { services.productOverrides.remember(updated) }
        return true
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
            services.notifications.scheduleExpiryReminder(for: item)
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
            newItems.forEach(services.notifications.scheduleExpiryReminder)
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
        let newCount = item.count + delta
        if delta < 0 {
            // Using food up is recorded as yours, so roommates can split what each of them ate.
            do {
                try await services.repository.useItem(id: item.id, qty: min(-delta, item.count), name: item.name,
                                                       remaining: newCount, householdId: hid)
            } catch {
                showError(error)
                return
            }
            if newCount <= 0 {
                removedLocally(item, ranOut: true)
            } else if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].count = newCount
            }
            return
        }
        do {
            try await services.repository.incrementCount(itemId: item.id, by: delta, householdId: hid)
            if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx].count = newCount }
        } catch {
            showError(error)
        }
    }

    func delete(_ item: FridgeItem, ranOut: Bool = false) async {
        guard let hid = householdId else { return }
        do {
            try await services.repository.deleteItem(id: item.id, householdId: hid)
            removedLocally(item, ranOut: ranOut)
        } catch {
            showError(error)
        }
    }

    private func removedLocally(_ item: FridgeItem, ranOut: Bool) {
        items.removeAll { $0.id == item.id }
        services.notifications.cancelExpiryReminder(itemId: item.id)
        if ranOut {
            services.notifications.notifyNow(id: "runout-\(item.id)", title: "You're out of \(item.name)",
                                             body: "Add it to the shopping list?")
            showMessage("Out of \(item.name)", actionTitle: "Add to list") { [weak self] in
                self?.addToShoppingList(name: item.name, barcode: item.barcode)
            }
        }
    }

    func setExpiry(_ item: FridgeItem, to date: Date) async {
        var updated = item
        updated.expiresAt = date
        updated.expiryIsEstimated = false
        _ = await save(updated)
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

    // MARK: Checks (recalls + watched prices) — shared by BGAppRefreshTask and "Run checks now"

    @discardableResult
    func runChecks() async -> String {
        guard let hid = householdId else { return "No household" }
        isRunningChecks = true
        defer { isRunningChecks = false }
        var notes: [String] = []

        // Recalls
        do {
            let recalls = try await services.recalls.recentRecalls(days: 90)
            var flagged = 0
            for item in items where item.recallFlag == nil {
                guard let recall = services.recallMatcher.match(item, in: recalls) else { continue }
                var updated = item
                updated.recallFlag = recall.asFlag
                try await services.repository.saveItem(updated, householdId: hid)
                upsertLocal(updated)
                flagged += 1
                services.notifications.notifyNow(id: "recall-\(item.id)", title: "Recall: \(item.name)",
                                                 body: recall.reason)
            }
            notes.append("\(recalls.count) recalls checked, \(flagged) new match\(flagged == 1 ? "" : "es")")
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

    private func checkWatchedPrices(householdId hid: String) async -> String {
        let watchlist = profile?.watchlist ?? []
        guard !watchlist.isEmpty else { return "No watched prices" }
        let coordinate = await currentCoordinate()
        let radius = profile?.searchRadiusMiles ?? 10
        guard let store = try? await services.kroger.locations(near: coordinate, radiusMiles: radius, limit: 1).first else {
            return "No Kroger store in range"
        }
        var drops = 0
        for upc in watchlist {
            let item = items.first { $0.normalizedBarcode == upc }
            let name = item?.name ?? upc
            let price: Double?
            if services.kroger.isLive {
                price = (try? await services.kroger.price(upc: upc, term: name, locationId: store.id))?.map(\.effective) ?? nil
            } else {
                let reference = services.mockPrices.referencePrice(categoryID: item?.category ?? "")
                price = services.mockPrices.price(upc: upc, name: name, chain: store.chain, referencePrice: reference)
            }
            guard let price else { continue }
            let previous = try? await services.repository.priceHistory(upc: upc, householdId: hid)
            if let previous, price < previous.lastPrice - 0.001 {
                drops += 1
                notifyPriceDrop(name: name, price: price, previous: previous.lastPrice, store: store.name)
            }
            try? await services.repository.savePriceHistory(
                PriceHistory(upc: upc, lastPrice: price, lastStoreId: store.id, checkedAt: .now), householdId: hid)
        }
        return "\(watchlist.count) watched price\(watchlist.count == 1 ? "" : "s"), \(drops) drop\(drops == 1 ? "" : "s")"
    }

    private func notifyPriceDrop(name: String, price: Double, previous: Double, store: String) {
        services.notifications.notifyNow(
            id: "price-\(name)-\(Int(Date.now.timeIntervalSince1970))",
            title: "Price drop: \(name)",
            body: "Now \(price.formatted(.currency(code: "USD"))) at \(store) (was \(previous.formatted(.currency(code: "USD"))))."
        )
    }

    /// Called by the BGAppRefreshTask. The app may be cold-launched in the background.
    func runBackgroundChecks() async {
        if phase == .launching { await bootstrap() }
        guard let hid = householdId else { return }
        if !itemsLoaded, let fetched = try? await services.repository.fetchItems(householdId: hid) {
            items = fetched
        }
        await runChecks()
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
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
            seed.forEach(services.notifications.scheduleExpiryReminder)
            if profile?.allergens.isEmpty ?? true {
                try await updateProfile { $0.allergens = [Allergen.sesame.rawValue] }
            }
            if !silently { showMessage("Added \(seed.count) demo items") }
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
        // Run it through the real matcher so the demo exercises the same path as live data.
        let matched = services.recallMatcher.match(target, in: [recall]) ?? recall
        var updated = target
        updated.recallFlag = matched.asFlag
        do {
            try await services.repository.saveItem(updated, householdId: hid)
            upsertLocal(updated)
            services.notifications.notifyNow(id: "recall-\(target.id)", title: "Recall: \(target.name)", body: matched.reason)
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
        notifyPriceDrop(name: item.name, price: high - 1.0, previous: high, store: "Kroger")
        try? await services.repository.savePriceHistory(
            PriceHistory(upc: item.normalizedBarcode ?? item.id, lastPrice: high, lastStoreId: "sim", checkedAt: .now),
            householdId: hid)
        showMessage("Simulated price drop for \(item.name)")
    }

    func testExpiryNotification() {
        guard let item = sortedItems.first else { showMessage("Add an item first"); return }
        let days = item.daysUntilExpiry()
        services.notifications.notifyNow(id: "expiry-test-\(item.id)", title: "\(item.name) expires \(days <= 1 ? "tomorrow" : "in \(days) days")",
                                         body: "Use it up before it goes to waste.")
    }
}

extension KrogerPrice {
    nonisolated var effective: Double { promo.map { min($0, regular) } ?? regular }
}
