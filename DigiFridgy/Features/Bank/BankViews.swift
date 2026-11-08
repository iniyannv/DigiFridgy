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
                    Text("Saved \(fund.usd)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hh.week_spend.usd)
                    .font(.title2.bold()).monospacedDigit()
                    .foregroundStyle(hh.week_spend > hh.budget ? Tone.warning.color : .primary)
                Text("of \(hh.budget.usd)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            BudgetBar(spent: hh.week_spend, budget: hh.budget)
            Text(hh.week_waste > 0
                 ? "\(hh.week_waste.usd) of food wasted this week"
                 : "Nothing wasted this week")
                .font(.caption)
                .foregroundStyle(hh.week_waste > 0 ? Tone.warning.color : .secondary)
            if let streak = hh.streak { StreakLine(streak: streak) }
            if let debt = myDebt {
                Label("You owe \(debt.to_name) \(debt.amount.usd)",
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect a card").font(.subheadline.weight(.semibold))
                Text("Groceries you buy land in the fridge with what they cost, and you get a weekly budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Connect") { showConnect = true }
                .buttonStyle(.glassProminent)
        }
        .padding(.vertical, 4)
    }
}

struct BudgetBar: View {
    var spent: Double
    var budget: Double

    var body: some View {
        ProgressView(value: min(spent, budget), total: max(budget, 1))
            .tint(spent > budget ? .orange : spent > budget * 0.85 ? .orange.opacity(0.7) : .green)
            .accessibilityValue(spent > budget ? "Over budget" : "\(Int((spent / max(budget, 1)) * 100)) percent of budget")
    }
}

// MARK: - Detail

struct BankDetailView: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showConnect = false
    @State private var showAddFromCard = false
    @State private var confirmSweep = false

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
                EmptyStateView(symbol: "building.columns",
                               title: "No card connected",
                               message: "Connect a card and groceries you buy land in the fridge automatically, with what they cost.",
                               primaryTitle: "Connect a card", primary: { showConnect = true })
            }
        }
        .navigationTitle("Grocery budget")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showConnect) { ConnectBankSheet() }
        .sheet(isPresented: $showAddFromCard) { AddFromCardSheet() }
        .refreshable { await bank.refresh() }
        .task { await bank.refreshSettle() }
    }

    private func weekSection(_ hh: BankHousehold) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hh.week_spend.usd)
                        .font(.largeTitle.bold()).monospacedDigit()
                    Text("of \(hh.budget.usd)").foregroundStyle(.secondary)
                    Spacer()
                }
                BudgetBar(spent: hh.week_spend, budget: hh.budget)
                Text(hh.week_spend > hh.budget
                     ? "\((hh.week_spend - hh.budget).usd) over budget"
                     : "\((hh.budget - hh.week_spend).usd) left this week")
                    .font(.subheadline)
                    .foregroundStyle(hh.week_spend > hh.budget ? Tone.warning.color : .secondary)
                if let streak = hh.streak { StreakLine(streak: streak) }
            }
            .padding(.vertical, 4)
            LabeledContent("Wasted this week") {
                Text(hh.week_waste.usd)
                    .monospacedDigit().foregroundStyle(hh.week_waste > 0 ? Tone.warning.color : .secondary)
            }
            LabeledContent("Wasted all time") {
                Text(hh.waste_total.usd).monospacedDigit()
            }
        } header: {
            Text("Groceries this week")
        } footer: {
            Text("To change your weekly budget, text your fridge “BUDGET 120”. Food only counts as wasted when it expires or gets tossed.")
        }
    }

    private var fridgeSection: some View {
        Section {
            if cardItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing from your card yet").font(.subheadline.weight(.semibold))
                    Text("Groceries you buy with your card appear here and in your fridge.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Add from card", systemImage: "creditcard") { showAddFromCard = true }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            ForEach(cardItems) { item in
                NavigationLink { ItemDetailView(itemId: item.id) } label: {
                    HStack {
                        InventoryRow(item: item)
                        if let value = item.value {
                            Text(value.usd)
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
                Text("\(total.usd) of groceries to use up.")
            }
        }
    }

    private func accountsSection(_ hh: BankHousehold) -> some View {
        Section {
            LabeledContent("Everyday Checking") { money(hh.checking_balance) }
            LabeledContent("Grocery Fund") { money(hh.fund_balance) }
            Button {
                confirmSweep = true
            } label: {
                HStack {
                    Label("Save what's left this week", systemImage: "arrow.right.circle")
                    Spacer()
                    if bank.isBusy { ProgressView() }
                }
            }
            .disabled(bank.isBusy || hh.weekLeft <= 0)
            .confirmationDialog("Save \(max(hh.weekLeft, 0).usd)?", isPresented: $confirmSweep, titleVisibility: .visible) {
                Button("Text me to confirm") {
                    Task {
                        do { app.showMessage(try await bank.sweep()) } catch { app.showError(error) }
                    }
                }
            } message: {
                Text("Your fridge texts you first. The money moves to the Grocery Fund only when you reply YES.")
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("The Grocery Fund is a savings account for grocery money you didn't spend. This is a demo bank with made-up balances, never your real accounts.")
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
                Text("Couldn't set up texting. Try connecting again in a minute.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(hh.members, id: \.self) { member in
                Label(PhoneFormat.pretty(member.components(separatedBy: " →").first), systemImage: "iphone")
            }
            if bank.state?.mock_photon == true {
                HStack {
                    StatusChip(text: "Demo", tone: .warning)
                    Text("Texts are simulated; nothing is sent.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iMessage")
        } footer: {
            Text("Send \"hi\" first. After that it texts when groceries post, before food expires, and when you're under budget. Text STOP anytime.")
        }
    }

    private func money(_ value: Double?) -> some View {
        Text(value.map { $0.usd } ?? "–").monospacedDigit()
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
                            .font(.largeTitle).foregroundStyle(.tint)
                            .accessibilityHidden(true)
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
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color)
                    }
                }

                Section {
                    Text("This connects a demo bank with made-up purchases, never your real accounts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect a card")
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
                Button("Connect a card", systemImage: "building.columns") { showConnect = true }
            case .offline:
                Label("Card connection isn't available right now. Try again later.", systemImage: "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(.secondary)
            case .unknown:
                HStack { Text("Checking…").foregroundStyle(.secondary); Spacer(); ProgressView() }
            }
        } header: {
            Text("Card & iMessage")
        } footer: {
            Text(bank.isLinked
                 ? "Card purchases stock this household's fridge. Anyone who joins with the invite code sees the same budget."
                 : "Connect a card and your groceries land in the fridge automatically, and your fridge can text you on iMessage.")
        }
        .sheet(isPresented: $showConnect) { ConnectBankSheet() }
    }
}

/// Where the bank + iMessage backend runs. Developer settings only.
struct BankServerSection: View {
    @Environment(BankStore.self) private var bank

    var body: some View {
        @Bindable var bank = bank
        Section {
            if case .offline(let message) = bank.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Tone.warning.color)
            }
            TextField("Server, e.g. http://192.168.1.20:8010", text: $bank.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
                .onSubmit { Task { await bank.refresh() } }
            if bank.isServerOverridden {
                Button("Use the build's server\(BankStore.defaultServer.isEmpty ? "" : " (\(BankStore.defaultServer))")",
                       systemImage: "arrow.uturn.backward") { bank.resetServer() }
                    .font(.callout)
            }
        } header: {
            Text("Bank server")
        } footer: {
            Text("The DigiFridgy server connects the bank and iMessage. The Simulator can use localhost; on an iPhone use your Mac's Wi-Fi address, e.g. http://192.168.1.20:8010.")
        }
    }
}

/// Bank demo controls, shown with the other demo tools once a bank is connected.
struct BankDemoSection: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @State private var basket = BankBasket.all[0]
    /// Buying and skipping days change real (sandbox) bank data, so each asks first.
    @State private var pending: PendingDemoAction?

    private struct PendingDemoAction: Identifiable {
        let id = UUID()
        var title: String
        var button: String
        var detail: String
        var work: () async throws -> String
    }

    var body: some View {
        if bank.isLinked {
            Section {
                Picker("Basket", selection: $basket) {
                    ForEach(BankBasket.all) { b in
                        Text("\(b.title) · \(b.store)").tag(b)
                    }
                }
                Button("Buy with card", systemImage: "creditcard") {
                    let chosen = basket
                    pending = PendingDemoAction(
                        title: "Buy \(chosen.title.lowercased()) at \(chosen.store)?", button: "Buy with card",
                        detail: "Creates a card purchase on your connected (sandbox) bank account.") {
                        try await bank.buy(chosen)
                    }
                }
                HStack {
                    Button("+1 day") { confirmAdvance(1) }
                    Spacer()
                    Button("+3 days") { confirmAdvance(3) }
                }
                .buttonStyle(.bordered)
                Button("Offer to save what's left", systemImage: "banknote") { act { try await bank.sweep() } }
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
                    Text("Buying creates a demo card purchase; the items land in the fridge within a few seconds. Demo clock: \(s.now_local)\(s.offset_days > 0 ? " (+\(s.offset_days.formatted()) days)" : ""). Offer to save before skipping past Monday; a new week resets spending.")
                }
            }
            .disabled(bank.isBusy)
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { action in
                Button(action.button) { act(action.work) }
            } message: { action in
                Text(action.detail)
            }
        }
    }

    private func confirmAdvance(_ days: Int) {
        pending = PendingDemoAction(
            title: "Skip ahead \(days) day\(days == 1 ? "" : "s")?", button: "Skip \(days) day\(days == 1 ? "" : "s")",
            detail: "Moves the server's demo clock forward for everyone: food may expire and texts may be sent. It can't be undone.") {
            try await bank.advance(days: days)
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
