import SwiftUI

// The bank lives inside the household: a budget card on the Fridge tab, card purchases in the
// fridge list, and setup + demo controls in Settings. Everything here reads the shared household.

// MARK: - Fridge tab card

/// Shown under the fridge summary. Hidden while the bank server is unreachable.
struct BankBudgetCard: View {
    @Environment(BankStore.self) private var bank
    @State private var showConnect = false

    var body: some View {
        Group {
            if let hh = bank.household {
                NavigationLink { BankDetailView() } label: { linked(hh) }
            } else if bank.status == .notLinked {
                connectPrompt
            }
        }
        .sheet(isPresented: $showConnect) { ConnectBankSheet() }
    }

    private func linked(_ hh: BankHousehold) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Groceries this week", systemImage: "creditcard")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let fund = hh.fund_balance {
                    Text("Fund \(fund.formatted(.currency(code: "USD")))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hh.week_spend.formatted(.currency(code: "USD")))
                    .font(.title2.bold()).monospacedDigit()
                    .foregroundStyle(hh.week_spend > hh.budget ? .orange : .primary)
                Text("of \(hh.budget.formatted(.currency(code: "USD")))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            BudgetBar(spent: hh.week_spend, budget: hh.budget)
            Text(hh.week_waste > 0
                 ? "\(hh.week_waste.formatted(.currency(code: "USD"))) of food wasted this week"
                 : "Nothing wasted this week")
                .font(.caption)
                .foregroundStyle(hh.week_waste > 0 ? .orange : .secondary)
            if let streak = hh.streak { StreakLine(streak: streak) }
            if let debt = myDebt {
                Label("You owe \(debt.to_name) \(debt.amount.formatted(.currency(code: "USD")))",
                      systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var myDebt: SettleDebt? {
        guard let me = bank.household?.id else { return nil }
        return bank.settle?.debts.first { $0.from_id == me && $0.amount >= 1 }
    }

    private var connectPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect your bank").font(.subheadline.weight(.semibold))
                Text("Card purchases stock this fridge and track your grocery budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Connect") { showConnect = true }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct BudgetBar: View {
    var spent: Double
    var budget: Double

    var body: some View {
        ProgressView(value: min(spent, budget), total: max(budget, 1))
            .tint(spent > budget ? .orange : spent > budget * 0.85 ? .yellow : .green)
    }
}

// MARK: - Detail

struct BankDetailView: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    private var cardItems: [FridgeItem] { app.sortedItems.filter(\.isCardPurchase) }

    var body: some View {
        List {
            if let hh = bank.household {
                weekSection(hh)
                PurchasesSection()
                RoommatesSection()
                fridgeSection
                accountsSection(hh)
                textSection(hh)
            } else {
                ContentUnavailableView("Bank not connected", systemImage: "building.columns",
                                       description: Text("Connect a bank in Settings to see your grocery budget."))
            }
        }
        .navigationTitle("Grocery budget")
        .refreshable { await bank.refresh() }
        .task { await bank.refreshSettle() }
    }

    private func weekSection(_ hh: BankHousehold) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hh.week_spend.formatted(.currency(code: "USD")))
                        .font(.largeTitle.bold()).monospacedDigit()
                    Text("of \(hh.budget.formatted(.currency(code: "USD")))").foregroundStyle(.secondary)
                    Spacer()
                }
                BudgetBar(spent: hh.week_spend, budget: hh.budget)
                Text(hh.week_spend > hh.budget
                     ? "\((hh.week_spend - hh.budget).formatted(.currency(code: "USD"))) over budget"
                     : "\((hh.budget - hh.week_spend).formatted(.currency(code: "USD"))) left this week")
                    .font(.subheadline)
                    .foregroundStyle(hh.week_spend > hh.budget ? .orange : .secondary)
                if let streak = hh.streak { StreakLine(streak: streak) }
            }
            .padding(.vertical, 4)
            LabeledContent("Wasted this week") {
                Text(hh.week_waste.formatted(.currency(code: "USD")))
                    .monospacedDigit().foregroundStyle(hh.week_waste > 0 ? .orange : .secondary)
            }
            LabeledContent("Wasted all time") {
                Text(hh.waste_total.formatted(.currency(code: "USD"))).monospacedDigit()
            }
        } header: {
            Text("Groceries this week")
        } footer: {
            Text("Text BUDGET <amount> to change the weekly budget. Money only counts as wasted when food expires or gets tossed.")
        }
    }

    private var fridgeSection: some View {
        Section {
            if cardItems.isEmpty {
                Text("Groceries you buy with your card show up here and in your fridge.")
                    .foregroundStyle(.secondary)
            }
            ForEach(cardItems) { item in
                NavigationLink { ItemDetailView(itemId: item.id) } label: {
                    HStack {
                        InventoryRow(item: item)
                        if let value = item.value {
                            Text(value.formatted(.currency(code: "USD")))
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("In the fridge from your card")
        } footer: {
            let total = cardItems.compactMap(\.value).reduce(0, +)
            if total > 0 {
                Text("\(total.formatted(.currency(code: "USD"))) of groceries to use up.")
            }
        }
    }

    private func accountsSection(_ hh: BankHousehold) -> some View {
        Section {
            LabeledContent("Everyday Checking") { money(hh.checking_balance) }
            LabeledContent("Grocery Fund") { money(hh.fund_balance) }
            Button {
                Task {
                    do { app.showMessage(try await bank.sweep()) } catch { app.showError(error) }
                }
            } label: {
                Label("Move what's left to the Grocery Fund", systemImage: "arrow.right.circle")
            }
            .disabled(bank.isBusy)
        } header: {
            Text("Accounts")
        } footer: {
            Text(bank.state?.mock_nessie == true
                 ? "SIMULATED bank data. You get a text first; money only moves when you reply YES."
                 : "Capital One Nessie sandbox (synthetic data, never your real accounts). You get a text first; money only moves when you reply YES.")
        }
    }

    // Shared lines can't text first, so each person has to send the first message.
    private func textSection(_ hh: BankHousehold) -> some View {
        Section {
            if let line = bank.line {
                LabeledContent("Text your fridge") {
                    Text(PhoneFormat.pretty(line)).monospacedDigit().textSelection(.enabled)
                }
                Button {
                    if let url = URL(string: "sms:\(line)&body=hi") { openURL(url) }
                } label: {
                    Label("Open Messages", systemImage: "message")
                }
            } else {
                Text("Photon couldn't assign an iMessage line. Check the server log, then connect again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(hh.members, id: \.self) { member in
                Label(PhoneFormat.pretty(member.components(separatedBy: " →").first), systemImage: "iphone")
            }
            if bank.state?.mock_photon == true {
                Label("SIMULATED iMessage: no real texts are sent", systemImage: "exclamationmark.bubble")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("iMessage")
        } footer: {
            Text("Send \"hi\" first. After that it texts when groceries post, before food expires, and when you're under budget. Text STOP anytime.")
        }
    }

    private func money(_ value: Double?) -> some View {
        Text(value.map { $0.formatted(.currency(code: "USD")) } ?? "–").monospacedDigit()
    }
}

// MARK: - Connect

struct ConnectBankSheet: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var phone = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty && phone.filter(\.isNumber).count >= 10
            && app.household != nil && !bank.isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 36)).foregroundStyle(.tint)
                        Text("Your card stocks \(app.household?.name ?? "your fridge")")
                            .font(.title3.bold())
                        Text("Groceries you buy show up in this fridge for everyone in the household, with what they cost. Your fridge texts you on iMessage before food goes bad and tracks your weekly budget.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Last name (optional)", text: $lastName)
                        .textContentType(.familyName)
                    TextField("iPhone number", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                } footer: {
                    Text("Use the iPhone number you'll text your fridge from.")
                }
                .focused($focused)

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    Text("Uses synthetic demo bank data from Capital One's Nessie sandbox, never your real accounts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect bank")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if bank.isBusy {
                        ProgressView()
                    } else {
                        Button("Connect", action: connect).disabled(!canSubmit)
                    }
                }
            }
            .onAppear {
                let name = app.profile?.displayName ?? ""
                if firstName.isEmpty, name != "Me" { firstName = name.capitalized }
            }
        }
        .interactiveDismissDisabled(bank.isBusy)
    }

    private func connect() {
        guard let code = app.household?.inviteCode else { return }
        focused = false
        error = nil
        Task {
            do {
                let message = try await bank.connect(
                    firstName: firstName.trimmingCharacters(in: .whitespaces),
                    lastName: lastName.trimmingCharacters(in: .whitespaces), phone: phone, inviteCode: code)
                app.showMessage(message)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings

struct BankSettingsSection: View {
    @Environment(BankStore.self) private var bank
    @State private var showConnect = false

    var body: some View {
        @Bindable var bank = bank
        Section {
            switch bank.status {
            case .linked:
                NavigationLink { BankDetailView() } label: {
                    LabeledContent("Grocery budget", value: bank.handle.map { PhoneFormat.pretty($0) } ?? "Connected")
                }
            case .notLinked:
                Button("Connect bank", systemImage: "building.columns") { showConnect = true }
            case .offline(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            case .unknown:
                HStack { Text("Checking…").foregroundStyle(.secondary); Spacer(); ProgressView() }
            }
            TextField("Server", text: $bank.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
                .onSubmit { Task { await bank.refresh() } }
        } header: {
            Text("Bank & iMessage")
        } footer: {
            Text(bank.isLinked
                 ? "Card purchases stock this household's fridge. Anyone who joins with the invite code sees the same budget."
                 : "The DigiFridgey server connects your bank and iMessage. The Simulator can use localhost; on an iPhone use your Mac's Wi-Fi address, e.g. http://192.168.1.20:8010.")
        }
        .sheet(isPresented: $showConnect) { ConnectBankSheet() }
    }
}

/// Bank demo controls, shown with the other demo tools once a bank is connected.
struct BankDemoSection: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @State private var basket = BankBasket.all[0]

    var body: some View {
        if bank.isLinked {
            Section {
                Picker("Basket", selection: $basket) {
                    ForEach(BankBasket.all) { b in
                        Text("\(b.title) · \(b.store)").tag(b)
                    }
                }
                Button("Buy with card", systemImage: "creditcard") { act { try await bank.buy(basket) } }
                HStack {
                    Button("+1 day") { act { try await bank.advance(days: 1) } }
                    Spacer()
                    Button("+3 days") { act { try await bank.advance(days: 3) } }
                }
                .buttonStyle(.bordered)
                Button("Send budget sweep offer", systemImage: "banknote") { act { try await bank.sweep() } }
                if others.isEmpty {
                    Button("Add a roommate (Sam, own card)", systemImage: "person.badge.plus") {
                        act { try await bank.addRoommate(name: "Sam") }
                    }
                } else {
                    ForEach(others) { mate in
                        Menu {
                            ForEach(Array(Set(app.items.map(\.name))).sorted(), id: \.self) { name in
                                Button(name) { act { try await bank.roommateUses(mate, item: name) } }
                            }
                        } label: {
                            Label("\(mate.name) uses…", systemImage: "fork.knife")
                        }
                    }
                }
            } header: {
                Text("Bank demo")
            } footer: {
                if let s = bank.state {
                    Text("Buying creates a Nessie purchase; the items land in the fridge within a few seconds. Server clock: \(s.now_local)\(s.offset_days > 0 ? " (+\(s.offset_days.formatted()) days)" : ""). Run the sweep before skipping past Monday; a new week resets spending.")
                }
            }
            .disabled(bank.isBusy)
        }
    }

    private var others: [SettleRoommate] {
        (bank.settle?.roommates ?? []).filter { $0.id != bank.household?.id }
    }

    private func act(_ work: @escaping () async throws -> String) {
        Task {
            do { app.showMessage(try await work()) } catch { app.showError(error) }
        }
    }
}
