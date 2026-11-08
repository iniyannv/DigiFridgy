import SwiftUI

// Grocery money from the bank's side: what happened to each card purchase, whether you overpaid,
// the weekly savings streak, and settling up with roommates who share the fridge.

private func usd(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

private func shortDate(_ iso: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: iso) else { return iso }
    return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

// MARK: - Streak

/// "Waste less, save more" in one line.
struct StreakLine: View {
    var streak: BankStreak

    var body: some View {
        if let text {
            Label(text, systemImage: streak.weeks > 0 ? "flame.fill" : "leaf")
                .font(.caption)
                .foregroundStyle(streak.weeks > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private var text: String? {
        var parts: [String] = []
        if streak.weeks > 0 {
            parts.append(streak.weeks == 1 ? "1 week under budget" : "\(streak.weeks) weeks in a row under budget")
        }
        if streak.saved > 0 { parts.append("\(usd(streak.saved)) saved") }
        if streak.waste_trend < -0.005 { parts.append("\(usd(-streak.waste_trend)) less waste than last week") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Breakdown

private struct Part: Identifiable {
    var id: String
    var label: String
    var value: Double
    var color: Color
}

private func parts(_ b: PurchaseBreakdown) -> [Part] {
    [Part(id: "eaten", label: "Eaten", value: b.eaten, color: .green),
     Part(id: "wasted", label: "Wasted", value: b.wasted, color: .orange),
     Part(id: "in_fridge", label: "In the fridge", value: b.in_fridge, color: .blue),
     Part(id: "not_added", label: "Not added", value: b.not_added, color: .gray),
     Part(id: "other", label: "Tax & other", value: b.other, color: Color(.systemGray4))]
        .filter { $0.value >= 0.01 }
}

/// One card charge split into eaten / wasted / still in the fridge.
struct BreakdownBar: View {
    var breakdown: PurchaseBreakdown
    var height: CGFloat = 8

    var body: some View {
        let items = parts(breakdown)
        let total = max(items.map(\.value).reduce(0, +), 0.01)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(items) { p in
                    Rectangle().fill(p.color)
                        .frame(width: max(2, (geo.size.width - CGFloat(items.count - 1) * 2) * p.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(items.map { "\($0.label) \(usd($0.value))" }.joined(separator: ", "))
    }
}

private struct BreakdownSummary: View {
    var breakdown: PurchaseBreakdown

    var body: some View {
        let b = breakdown
        var bits = ["\(usd(b.eaten)) eaten"]
        if b.wasted >= 0.01 { bits.append("\(usd(b.wasted)) wasted") }
        if b.in_fridge >= 0.01 { bits.append("\(usd(b.in_fridge)) in fridge") }
        return Text(bits.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Purchases section

/// Recent grocery card purchases, each split by what happened to the food.
struct PurchasesSection: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @State private var purchases: [CardPurchase] = []
    @State private var loaded = false

    var body: some View {
        Section {
            if loaded && purchases.isEmpty {
                Text("Grocery purchases on your card from the last two weeks show up here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(purchases) { p in
                NavigationLink { PurchaseDetailView(purchase: p) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.merchant).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(usd(p.amount)).font(.subheadline).monospacedDigit()
                        }
                        if let b = p.breakdown {
                            BreakdownBar(breakdown: b)
                            BreakdownSummary(breakdown: b)
                        }
                        Text(shortDate(p.date)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Where your grocery money went")
        } footer: {
            let wasted = purchases.compactMap(\.breakdown).map(\.wasted).reduce(0, +)
            if wasted >= 0.01 {
                Text("\(usd(wasted)) of these trips ended up in the trash.")
            }
        }
        // Reload when the fridge changes: using or tossing food moves money between the parts.
        .task(id: app.items.map(\.count).reduce(0, +)) { await load() }
    }

    private func load() async {
        if let list = try? await bank.cardPurchases() { purchases = list }
        loaded = true
    }
}

// MARK: - One purchase

struct PurchaseDetailView: View {
    @Environment(AppState.self) private var app
    let purchase: CardPurchase

    /// Live Kroger price per line index (nil = not carried).
    @State private var kroger: [Int: KrogerPrice?] = [:]
    @State private var krogerStore: Store?
    @State private var checking = false
    @State private var compareError: String?

    var body: some View {
        List {
            if let b = purchase.breakdown {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(usd(purchase.amount)).font(.largeTitle.bold()).monospacedDigit()
                        BreakdownBar(breakdown: b, height: 14)
                    }
                    .padding(.vertical, 4)
                    ForEach(parts(b)) { p in
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(p.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label)
                                if let names = b.names[p.id], !names.isEmpty {
                                    Text(names.map(\.capitalized).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(usd(p.value)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("\(purchase.merchant) · \(shortDate(purchase.date))")
                } footer: {
                    Text("From the card charge and what happened in the fridge since: used up, expired or tossed, or still there.")
                }
            }
            compareSection
        }
        .navigationTitle(purchase.merchant)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Kroger

    private var isLive: Bool { app.services.kroger.isLive }

    private var savings: Double {
        purchase.lines.reduce(0) { sum, line in
            guard let price = kroger[line.index] ?? nil else { return sum }
            let paid = line.total / Double(max(line.qty, 1))
            return sum + max(0, paid - (price.promo ?? price.regular)) * Double(line.qty)
        }
    }

    private var compareSection: some View {
        Section {
            ForEach(purchase.lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.emoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.name.capitalized)
                        Text("You paid \(usd(line.total / Double(max(line.qty, 1))))\(line.qty > 1 ? " each" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    krogerCell(line)
                }
            }
            if isLive {
                Button {
                    Task { await compare() }
                } label: {
                    HStack {
                        Label(kroger.isEmpty ? "Compare with Kroger today" : "Check again", systemImage: "tag")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking)
            }
        } header: {
            Text("Did you overpay?")
        } footer: {
            if !isLive {
                Text("Live Kroger prices need KROGER_CLIENT_ID and KROGER_CLIENT_SECRET in Config/Secrets.xcconfig. Nothing here is estimated.")
            } else if let compareError {
                Text(compareError)
            } else if let store = krogerStore, !kroger.isEmpty {
                Text(savings >= 0.01
                     ? "You'd have paid \(usd(savings)) less at \(store.name) (\(store.distanceMiles.formatted(.number.precision(.fractionLength(1)))) mi) today. Live Kroger prices."
                     : "\(store.name) isn't cheaper today for these. Live Kroger prices.")
            }
        }
    }

    @ViewBuilder
    private func krogerCell(_ line: CardLine) -> some View {
        if let entry = kroger[line.index] {
            if let price = entry {
                let now = price.promo ?? price.regular
                let paid = line.total / Double(max(line.qty, 1))
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Kroger \(usd(now))").font(.subheadline).monospacedDigit()
                    if paid - now >= 0.01 {
                        Text("+\(usd(paid - now)) here").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("you did fine").font(.caption).foregroundStyle(.green)
                    }
                }
            } else {
                Text("not carried").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func compare() async {
        checking = true
        compareError = nil
        defer { checking = false }
        let services = app.services
        guard let here = await services.location.currentCoordinate() else {
            compareError = "Allow location access to find the nearest Kroger."
            return
        }
        do {
            let radius = app.profile?.searchRadiusMiles ?? 10
            guard let store = try await services.kroger.locations(near: here, radiusMiles: radius, limit: 1).first else {
                compareError = "No Kroger store within \(Int(radius)) miles."
                return
            }
            krogerStore = store
            let kroger = services.kroger
            let results = await withTaskGroup(of: (Int, KrogerPrice?).self) { group in
                for line in purchase.lines {
                    group.addTask { (line.index, try? await kroger.price(upc: nil, term: line.name, locationId: store.id)) }
                }
                var out: [Int: KrogerPrice?] = [:]
                for await (index, price) in group { out[index] = price }
                return out
            }
            self.kroger = results
        } catch {
            compareError = error.localizedDescription
        }
    }
}

// MARK: - Roommates

/// Settle-up between roommates who each connected their own bank to this fridge.
struct RoommatesSection: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @State private var confirming: SettleDebt?

    var body: some View {
        Section {
            if let s = bank.settle, s.roommates.count >= 2 {
                let me = bank.household?.id
                if s.debts.isEmpty {
                    Label("Everyone's square", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(s.debts) { debt in row(debt, me: me) }
                Text("Roommates: \(s.roommates.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Each roommate connects their own bank with this household's invite code. When someone uses food another roommate paid for (−1 here, or USED by text), they owe that share.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Roommates")
        } footer: {
            if bank.settle?.app_uses_available == false {
                Text("Uses by text count now. Taps in the app count once the updated SpacetimeDB module (server/) is published.")
            } else {
                Text("Paying is a Nessie transfer from your checking to theirs, in whole dollars. Nothing moves until you confirm.")
            }
        }
        .confirmationDialog(confirming.map { "Send \($0.to_name) \(usd(wholeDollars($0.amount)))?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { debt in
            Button("Send \(usd(wholeDollars(debt.amount))) from Everyday Checking") {
                Task {
                    do { app.showMessage(try await bank.pay(debt)) } catch { app.showError(error) }
                }
            }
        } message: { debt in
            Text("For \(debt.items.prefix(4).joined(separator: ", ")). The bank moves whole dollars; the cents stay on the tab.")
        }
    }

    private func wholeDollars(_ value: Double) -> Double { value.rounded(.down) }

    @ViewBuilder
    private func row(_ debt: SettleDebt, me: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(debt, me: me))
                if !debt.items.isEmpty {
                    Text(debt.items.prefix(4).map(\.capitalized).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if debt.from_id == me {
                Button("Pay") { confirming = debt }
                    .buttonStyle(.glassProminent).controlSize(.small)
                    .disabled(bank.isBusy || debt.amount < 1)
            } else if debt.to_id == me {
                Button("Ask") {
                    Task { do { app.showMessage(try await bank.ask(debt)) } catch { app.showError(error) } }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(bank.isBusy)
            }
        }
    }

    private func title(_ debt: SettleDebt, me: Int?) -> AttributedString {
        let amount = usd(debt.amount)
        var s: AttributedString
        if debt.from_id == me {
            s = AttributedString("You owe \(debt.to_name) \(amount)")
        } else if debt.to_id == me {
            s = AttributedString("\(debt.from_name) owes you \(amount)")
        } else {
            s = AttributedString("\(debt.from_name) owes \(debt.to_name) \(amount)")
        }
        if let range = s.range(of: amount) { s[range].font = .body.bold().monospacedDigit() }
        return s
    }
}
