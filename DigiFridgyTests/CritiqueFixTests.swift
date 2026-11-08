import Testing
import Foundation
@testable import DigiFridgy

// Tests for the iOS critique fixes (recalls, barcodes, receipts, expiry labels/dates, prices, reminders).

struct RecallConfidenceTests {
    let matcher = RecallMatcher()

    private func recall(_ description: String, firm: String = "", code: String = "", date: Date = .now) -> Recall {
        Recall(id: "F-0001-2026", reason: "Listeria", productDescription: description, codeInfo: code, firm: firm,
               date: date, classification: "Class I", url: "https://fda.gov")
    }

    @Test func brandlessNameOnlyMatchIsPossible() throws {
        let item = FridgeItem(name: "Baby Spinach", category: "leafy_greens", expiresAt: .now, source: .receipt)
        let hit = try #require(matcher.match(item, in: [recall("Fresh Express Baby Spinach 5 oz", firm: "Fresh Express")]))
        #expect(hit.confidence == .possible)
        #expect(hit.flag.isPossible)
        #expect(hit.flag.title.contains("Possible recall"))
    }

    @Test func brandAndNameMatchIsConfirmed() throws {
        let item = FridgeItem(name: "Classic Hummus", brand: "Sabra", category: "hummus", expiresAt: .now, source: .barcode)
        let hit = try #require(matcher.match(item, in: [recall("Sabra Classic Hummus 10 oz", firm: "Sabra Dipping Co")]))
        #expect(hit.confidence == .confirmed)
    }

    @Test func singleWordNameMatchesWhenBrandMatches() throws {
        let item = FridgeItem(name: "Spinach", brand: "Taylor Farms", category: "leafy_greens", expiresAt: .now, source: .barcode)
        let hit = try #require(matcher.match(item, in: [recall("Taylor Farms Spinach 10 oz bag", firm: "Taylor Farms")]))
        #expect(hit.confidence == .confirmed)
    }

    @Test func dismissedRecallIsSkipped() {
        var item = FridgeItem(name: "Baby Spinach", category: "leafy_greens", expiresAt: .now, source: .receipt)
        item.dismissedRecallIDs = ["F-0001-2026"]
        #expect(matcher.match(item, in: [recall("Fresh Express Baby Spinach")]) == nil)
    }

    @Test func recallLongBeforePurchaseIsSkipped() {
        let item = FridgeItem(name: "Baby Spinach", category: "leafy_greens", addedAt: .now, expiresAt: .now, source: .receipt)
        let old = recall("Fresh Express Baby Spinach", date: .now.addingTimeInterval(-60 * 86_400))
        #expect(matcher.match(item, in: [old]) == nil)
    }

    @Test func oldFlagsDecodeAsConfirmed() throws {
        let json = #"{"recallId":"F-1","reason":"Listeria","date":0}"#
        let flag = try JSONDecoder().decode(RecallFlag.self, from: Data(json.utf8))
        #expect(flag.confidence == .confirmed)
    }
}

struct BarcodeTests {
    @Test func expandsUPCE() {
        #expect(Barcode.expandUPCE("04252614") == "042100005264")
        #expect(Barcode.normalize("04252614") == "0042100005264")
    }

    @Test(arguments: [
        ("01234565", "012345000065"),   // last digit 5–9: manufacturer 5 digits, product 0000d6
        ("01234133", "012300000413"),   // last digit 3
        ("01234145", "012340000015"),   // last digit 4
    ])
    func expandsEveryUPCEForm(upce: String, upcA: String) {
        #expect(Barcode.expandUPCE(upce) == upcA)
    }

    @Test func leavesEAN8AndBadChecksAlone() {
        #expect(Barcode.expandUPCE("96385074") == nil)          // EAN-8 (number system 9)
        #expect(Barcode.normalize("96385074") == "96385074")
        #expect(Barcode.expandUPCE("04252615") == nil)          // wrong check digit
    }

    @Test func upcAStillNormalizesToEAN13() {
        #expect(Barcode.normalize("078742351865") == "0078742351865")
    }

    @Test func krogerProductIDFromExpandedUPCE() {
        #expect(LiveKrogerService.krogerProductID(fromUPC: Barcode.normalize("04252614")) == "0004210000526")
    }
}

struct ReceiptFalseDropTests {
    let parser = ReceiptParser()

    @Test(arguments: [
        ("FAGE TOTAL 0% 1.99", "FAGE", 1.99),
        ("CHOC CHIP COOKIES 3.49", "CHOC CHIP COOKIES", 3.49),
        ("MEMBER'S MARK EGGS 4.99", "MEMBER'S MARK EGGS", 4.99),
    ])
    func keepsRealItems(line: String, name: String, price: Double) throws {
        let item = try #require(parser.parse([line]).first)
        #expect(item.name.contains(name))
        #expect(item.price == price)
    }

    @Test(arguments: ["TOTAL 24.23", "GRAND TOTAL 31.10", "CHIP READ 24.23", "MEMBER # 1234 5.00", "TOTAL SAVINGS 2.00"])
    func stillDropsReceiptLines(line: String) {
        #expect(parser.parse([line]).isEmpty)
    }

    @Test func timeLineWithPriceIsKept() {
        #expect(parser.parse(["STORE HOURS 7:00 AM"]).isEmpty)
        #expect(parser.parse(["DELI 12:30 SANDWICH 5.99"]).count == 1)
    }

    @Test func pendingQuantityDoesNotSkipOverOtherLines() {
        let items = parser.parse(["2 @ 1.25", "THANK YOU", "BREAD 2.50"])
        #expect(items.first?.quantity == 1)
    }

    @Test func unitPriceSplitsTheLine() {
        #expect(ReceiptScanSheet.unitPrice(lineTotal: 2.48, count: 2) == 1.24)
        #expect(ReceiptScanSheet.unitPrice(lineTotal: nil, count: 1) == nil)
    }
}

struct ExpiryLabelTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }

    private func item(daysFromNow days: Int, estimated: Bool, now: Date) -> FridgeItem {
        let expiry = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return FridgeItem(name: "Milk", category: "milk", expiresAt: expiry, expiryIsEstimated: estimated, source: .barcode)
    }

    @Test(arguments: [-3, -1, 0, 1, 2, 10])
    func estimatedLabelsAlwaysSayEst(days: Int) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let label = item(daysFromNow: days, estimated: true, now: now).expiryLabel(now: now, calendar: calendar)
        #expect(label.hasPrefix("Est."))
    }

    @Test func printedLabelsDontSayEst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(item(daysFromNow: 2, estimated: false, now: now).expiryLabel(now: now, calendar: calendar) == "Exp. in 2d")
        #expect(item(daysFromNow: 1, estimated: true, now: now).expiryLabel(now: now, calendar: calendar) == "Est. exp. tomorrow")
        #expect(item(daysFromNow: -2, estimated: false, now: now).expiryLabel(now: now, calendar: calendar) == "Expired 2d ago")
    }

    @Test func recipeMatchLabelSaysEst() {
        #expect(RecipeMatch(itemName: "spinach", daysUntilExpiry: 1, expiryIsEstimated: true).expiryLabel == "Est. exp. tomorrow")
        #expect(RecipeMatch(itemName: "spinach", daysUntilExpiry: 1, expiryIsEstimated: false).expiryLabel == "Exp. tomorrow")
    }

    @Test func estimatedExpiryIsStartOfDay() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = ShelfLifeService.shared.estimatedExpiry(categoryID: "milk", from: start, calendar: calendar)
        #expect(expiry == calendar.startOfDay(for: expiry))
    }
}

struct CalendarDateTests {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func encoder(_ calendar: Calendar) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.userInfo[FridgeItem.calendarKey] = calendar
        return e
    }

    private func decoder(_ calendar: Calendar) -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        d.userInfo[FridgeItem.calendarKey] = calendar
        return d
    }

    @Test(arguments: [("Pacific/Auckland", "America/Los_Angeles"), ("America/Los_Angeles", "Asia/Tokyo"),
                      ("Europe/London", "Pacific/Honolulu")])
    func expiryDaySurvivesTimeZoneChange(from: String, to: String) throws {
        let writer = calendar(from), reader = calendar(to)
        // Late evening on Nov 10 where it was saved: the day printed on the label.
        let saved = writer.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
        let item = FridgeItem(name: "Yogurt", category: "yogurt", expiresAt: saved, expiryIsEstimated: false, source: .barcode)
        let data = try encoder(writer).encode(item)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["expiryDate"] as? String == "2026-11-10")

        let decoded = try decoder(reader).decode(FridgeItem.self, from: data)
        let parts = reader.dateComponents([.year, .month, .day], from: decoded.expiresAt)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 10)
        let now = reader.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        #expect(decoded.daysUntilExpiry(now: now, calendar: reader) == 2)
    }

    @Test func legacyMillisecondsStillDecode() throws {
        let chicago = calendar("America/Chicago")
        let instant = chicago.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!
        let json = #"{"id":"a","name":"Milk","expiresAt":\#(Int(instant.timeIntervalSince1970 * 1000))}"#
        let item = try decoder(chicago).decode(FridgeItem.self, from: Data(json.utf8))
        #expect(CalendarDay.string(from: item.expiresAt, calendar: chicago) == "2026-11-12")
    }

    @Test func expiresAtStaysMillisecondsForTheBackend() throws {
        let chicago = calendar("America/Chicago")
        let day = chicago.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let item = FridgeItem(name: "Milk", category: "milk", expiresAt: day, source: .barcode)
        let json = try #require(JSONSerialization.jsonObject(with: encoder(chicago).encode(item)) as? [String: Any])
        let ms = try #require(json["expiresAt"] as? NSNumber)
        // Noon UTC on Nov 10.
        #expect(ms.int64Value == 1_794_312_000_000)
    }
}

struct ShoppingEstimateTests {
    private func paidItem(_ name: String, price: Double) -> FridgeItem {
        FridgeItem(name: name, category: "milk", expiresAt: .now, source: .barcode, price: price)
    }

    @Test func paidPriceHasNoBadge() {
        let e = ShoppingEstimate.estimate(name: "milk", items: [paidItem("Whole Milk", price: 3.49)]) { _ in 9.99 }
        #expect(e.paid)
        #expect(e.price == 3.49)
        #expect(e.badge == nil)
        #expect(!e.priceText.hasPrefix("~"))
    }

    @Test func typicalPriceIsLabeled() {
        let e = ShoppingEstimate.estimate(name: "Eggs", items: [paidItem("Whole Milk", price: 3.49)]) { _ in 2.99 }
        #expect(!e.paid)
        #expect(e.badge == "Typical price")
        #expect(e.priceText.hasPrefix("~"))
    }

    @Test func matchesWholeWordsOnly() {
        let e = ShoppingEstimate.estimate(name: "corn", items: [paidItem("Popcorn", price: 4.00)]) { _ in 1.50 }
        #expect(!e.paid)
    }

    @Test func totalSaysWhenItIncludesTypicalPrices() {
        let paid = ShoppingEstimate(price: 3, paid: true), typical = ShoppingEstimate(price: 2, paid: false)
        #expect(ShoppingEstimate.totalText([paid, typical]).contains("includes typical prices"))
        #expect(!ShoppingEstimate.totalText([paid]).contains("typical"))
    }

    @Test func sampleMarkersSaySample() {
        let store = Store(id: "w", chain: "Walmart", name: "Walmart", address: "", coordinate: .demoFallback,
                          distanceMiles: 1, isKroger: false)
        #expect(PriceComparisonView.markerTitle(PriceQuote(store: store, price: 3.49, availability: .sample)).contains("Sample"))
        #expect(!PriceComparisonView.markerTitle(PriceQuote(store: store, price: 3.49, availability: .live)).contains("Sample"))
    }

    @Test func onlyLivePriceHistoryCounts() {
        #expect(PriceHistory(upc: "1", lastPrice: 1, lastStoreId: "kroger-123", checkedAt: .now).isLive)
        #expect(!PriceHistory(upc: "1", lastPrice: 1, lastStoreId: PriceHistory.samplePrefix + "sim", checkedAt: .now).isLive)
        #expect(!PriceHistory(upc: "1", lastPrice: 1, lastStoreId: "sim", checkedAt: .now).isLive)
    }
}

struct ReminderReconcileTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14))! }

    private func item(_ id: String, daysFromNow days: Int, count: Int = 1) -> FridgeItem {
        let expiry = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return FridgeItem(id: id, name: "Item \(id)", category: "milk", count: count, expiresAt: expiry, source: .barcode)
    }

    @Test func remindsAtNineTheDayBefore() throws {
        let spec = try #require(ReminderPlanner.spec(for: item("a", daysFromNow: 3), now: now, calendar: calendar))
        let parts = calendar.dateComponents([.day, .hour], from: spec.fireDate)
        #expect(parts.day == 10 && parts.hour == 9)
        #expect(!spec.isASAP)
        #expect(spec.title.contains("Est."))
    }

    @Test func shortWindowStillGetsAReminder() throws {
        let spec = try #require(ReminderPlanner.spec(for: item("a", daysFromNow: 0), now: now, calendar: calendar))
        #expect(spec.isASAP)
        #expect(spec.fireDate == now.addingTimeInterval(3600))
    }

    @Test func expiredOrUsedUpGetNone() {
        #expect(ReminderPlanner.spec(for: item("a", daysFromNow: -1), now: now, calendar: calendar) == nil)
        #expect(ReminderPlanner.spec(for: item("a", daysFromNow: 3, count: 0), now: now, calendar: calendar) == nil)
    }

    @Test func diffAddsRemovesAndReplaces() {
        let keep = item("keep", daysFromNow: 3), moved = item("moved", daysFromNow: 5), new = item("new", daysFromNow: 4)
        var pending = ReminderPlanner.desired(for: [keep, moved], now: now, calendar: calendar)
        pending["expiry.gone"] = ReminderSpec(fireDate: now.addingTimeInterval(86_400), title: "Gone", body: "", isASAP: false)
        // A roommate changed "moved" to expire a day earlier, deleted "gone" and added "new".
        let movedEarlier = item("moved", daysFromNow: 4)
        let desired = ReminderPlanner.desired(for: [keep, movedEarlier, new], now: now, calendar: calendar)
        let (add, remove) = ReminderPlanner.diff(pending: pending, desired: desired, now: now)
        #expect(Set(add.keys) == ["expiry.moved", "expiry.new"])
        #expect(remove == ["expiry.gone", "expiry.moved"])
    }

    @Test func pendingASAPReminderIsNotRescheduledEveryUpdate() {
        let soon = item("soon", daysFromNow: 0)
        let first = ReminderPlanner.desired(for: [soon], now: now, calendar: calendar)
        let later = now.addingTimeInterval(600)
        let again = ReminderPlanner.desired(for: [soon], now: later, calendar: calendar)
        let (add, remove) = ReminderPlanner.diff(pending: first, desired: again, now: later)
        #expect(add.isEmpty && remove.isEmpty)
    }

    @Test func mockServiceReconcilesToTheItems() async {
        let service = MockNotificationService()
        let a = FridgeItem(id: "a", name: "A", category: "milk", expiresAt: .now.addingTimeInterval(5 * 86_400), source: .barcode)
        let b = FridgeItem(id: "b", name: "B", category: "milk", expiresAt: .now.addingTimeInterval(6 * 86_400), source: .barcode)
        await service.reconcile(items: [a, b])
        #expect(Set(service.reminders.keys) == ["expiry.a", "expiry.b"])
        await service.reconcile(items: [b])
        #expect(Set(service.reminders.keys) == ["expiry.b"])
        service.removeAllReminders()
        #expect(service.reminders.isEmpty)
    }
}

struct NetworkingTests {
    @Test func backoffDoublesAndCaps() {
        #expect(SpacetimeHouseholdRepository.backoff(base: .seconds(2), failures: 1) == .seconds(4))
        #expect(SpacetimeHouseholdRepository.backoff(base: .seconds(2), failures: 10) == .seconds(30))
    }

    @Test func missingReducerIsRecognizedByMessage() {
        #expect(SpacetimeHouseholdRepository.isMissingReducer(.server(400, "No such reducer: use_item"), named: "use_item"))
        #expect(SpacetimeHouseholdRepository.isMissingReducer(.reducer("Reducer `use_item` does not exist"), named: "use_item"))
        #expect(!SpacetimeHouseholdRepository.isMissingReducer(.reducer("Item not found"), named: "use_item"))
        #expect(!SpacetimeHouseholdRepository.isMissingReducer(.server(404, ""), named: "use_item"))
    }

    @Test func rateLimitDelayHonorsRetryAfterWithACap() {
        #expect(APIClient.rateLimitDelay(retryAfter: "3", attempt: 1) == .seconds(3))
        #expect(APIClient.rateLimitDelay(retryAfter: "120", attempt: 1) == .seconds(10))
        #expect(APIClient.rateLimitDelay(retryAfter: nil, attempt: 2) == .seconds(2))
    }

    @Test func serverAddressNormalizes() {
        #expect(BankStore.normalizedServer("192.168.1.20:8010") == "http://192.168.1.20:8010")
        #expect(BankStore.normalizedServer("https://example.test") == "https://example.test")
        #expect(BankStore.normalizedServer("$(DIGIFRIDGEY_SERVER)") == "")
        #expect(BankStore.normalizedServer(nil) == "")
    }

    @Test func debtQuotesWholeDollars() {
        let debt = SettleDebt(from_id: 1, to_id: 2, from_name: "Sam", to_name: "Ana", amount: 12.75, items: [])
        #expect(debt.wholeDollars == 12)
    }
}
