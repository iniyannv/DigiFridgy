import SwiftUI

/// "Bank" tab: link your phone number to a (synthetic) Nessie bank account, then
/// watch grocery purchases stock the fridge while the agent texts you over iMessage.
struct BankView: View {
    @Environment(BankStore.self) private var bank

    var body: some View {
        NavigationStack {
            Group {
                if bank.isLinked {
                    BankDashboard()
                } else {
                    BankSignUpView()
                }
            }
            .navigationTitle(bank.isLinked ? (bank.householdName ?? "Bank") : "Link your bank")
        }
    }
}

// MARK: - Sign-up

struct BankSignUpView: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var phone = ""
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty && phone.filter(\.isNumber).count >= 10
    }

    var body: some View {
        @Bindable var bank = bank
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Your bank stocks your fridge")
                        .font(.title3.bold())
                    Text("Groceries you buy with your card show up in your fridge automatically, and your fridge texts you on iMessage before food goes bad.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .focused($focused)
                TextField("Last name (optional)", text: $lastName)
                    .textContentType(.familyName)
                    .focused($focused)
                TextField("iPhone number", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .focused($focused)
            } header: {
                Text("You")
            } footer: {
                Text("Use the iPhone number you'll text your fridge from.")
            }

            if let error = bank.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    focused = false
                    Task {
                        if let r = await bank.signUp(firstName: firstName, lastName: lastName, phone: phone) {
                            let line = PhoneFormat.pretty(r.text_this_number)
                            app.toast = Toast(message: line.isEmpty ? "Fridge created." : "Fridge created. Text hi to \(line).")
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if bank.isBusy { ProgressView() } else { Text("Create my fridge").bold() }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || bank.isBusy)
            } footer: {
                Text("Uses synthetic demo bank data from Capital One's Nessie sandbox, never your real accounts. Money only moves when you text YES. Text STOP anytime.")
            }

            ServerSection()
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }
}

// MARK: - Dashboard

struct BankDashboard: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var basket = BankBasket.all[0]
    @State private var confirmUnlink = false

    var body: some View {
        List {
            textCard
            if let error = bank.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let hh = bank.state?.household {
                moneySection(hh)
                fridgeSection(hh)
                if !hh.list.isEmpty {
                    Section("Shopping list") {
                        ForEach(hh.list, id: \.self) { Text($0) }
                    }
                }
            } else if bank.lastError == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            demoSection
            ServerSection()
            Section {
                Button("Unlink this phone", role: .destructive) { confirmUnlink = true }
            }
        }
        .refreshable { await bank.refresh() }
        .task {
            while !Task.isCancelled {
                await bank.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Unlink \(PhoneFormat.pretty(bank.handle))?", isPresented: $confirmUnlink,
                            titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { bank.unlink() }
        } message: {
            Text("This app stops showing the household. Signing up again with the same number brings it back.")
        }
    }

    // Shared lines can't text first, so the user has to send the first message.
    private var textCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Text your fridge", systemImage: "message.fill")
                    .font(.headline)
                if let line = bank.line {
                    Text(PhoneFormat.pretty(line))
                        .font(.system(.title, design: .rounded).bold())
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Text("Send \"hi\" from \(PhoneFormat.pretty(bank.handle)) first. After that it texts you when groceries post, before food expires, and when you're under budget.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: "sms:\(line)&body=hi") { openURL(url) }
                    } label: {
                        Label("Open Messages", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Text("Photon couldn't assign an iMessage line to your number. Check the server log, then sign up again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if bank.state?.mock_photon == true {
                    Label("SIMULATED iMessage: no real texts are sent", systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func moneySection(_ hh: BankHousehold) -> some View {
        Section {
            LabeledContent("Everyday Checking") { money(hh.checking_balance) }
            LabeledContent("Grocery Fund") { money(hh.fund_balance) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Groceries this week")
                    Spacer()
                    Text("\(hh.week_spend.formatted(.currency(code: "USD"))) of \(hh.budget.formatted(.currency(code: "USD")))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(hh.week_spend, hh.budget), total: max(hh.budget, 1))
                    .tint(hh.week_spend > hh.budget ? .orange : .green)
            }
            LabeledContent("Food wasted this week") {
                Text(hh.week_waste.formatted(.currency(code: "USD")))
                    .monospacedDigit()
                    .foregroundStyle(hh.week_waste > 0 ? .orange : .secondary)
            }
        } header: {
            Text("Bank")
        } footer: {
            if bank.state?.mock_nessie == true {
                Text("SIMULATED Nessie data.")
            } else {
                Text("Capital One Nessie sandbox (synthetic data). Balances are computed from Nessie's purchase, transfer and deposit records.")
            }
        }
    }

    private func money(_ value: Double?) -> some View {
        Text(value.map { $0.formatted(.currency(code: "USD")) } ?? "–").monospacedDigit()
    }

    private func fridgeSection(_ hh: BankHousehold) -> some View {
        Section {
            if hh.fridge.isEmpty {
                Text("Nothing yet. Buy groceries below and they'll show up here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(grouped(hh.fridge), id: \.item.name) { row in
                let item = row.item
                HStack {
                    Text(item.emoji)
                    Text(item.name)
                    if row.count > 1 {
                        Text("×\(row.count)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.expires)
                        .font(.subheadline)
                        .foregroundStyle(["today", "tomorrow"].contains(item.expires) ? .orange : .secondary)
                }
            }
        } header: {
            Text("Stocked from your card (\(hh.fridge.count) items)")
        }
    }

    /// Units of the same food collapse into one row; the list arrives sorted by expiry.
    private func grouped(_ items: [BankFridgeItem]) -> [(item: BankFridgeItem, count: Int)] {
        var order: [String] = []
        var rows: [String: (item: BankFridgeItem, count: Int)] = [:]
        for item in items {
            if let row = rows[item.name] {
                rows[item.name] = (row.item, row.count + 1)
            } else {
                order.append(item.name)
                rows[item.name] = (item, 1)
            }
        }
        return order.compactMap { rows[$0] }
    }

    private var demoSection: some View {
        Section {
            Picker("Basket", selection: $basket) {
                ForEach(BankBasket.all) { b in
                    Text("\(b.title) · \(b.store)").tag(b)
                }
            }
            Button {
                Task { if let msg = await bank.buy(basket) { app.toast = Toast(message: msg) } }
            } label: {
                Label("Buy with card (Nessie purchase)", systemImage: "creditcard")
            }
            HStack {
                Button("+1 day") { Task { if let msg = await bank.advance(days: 1) { app.toast = Toast(message: msg) } } }
                Spacer()
                Button("+3 days") { Task { if let msg = await bank.advance(days: 3) { app.toast = Toast(message: msg) } } }
            }
            .buttonStyle(.bordered)
            Button {
                Task { if let msg = await bank.sweep() { app.toast = Toast(message: msg) } }
            } label: {
                Label("Send budget sweep offer", systemImage: "banknote")
            }
        } header: {
            Text("Demo controls")
        } footer: {
            if let s = bank.state {
                Text("App clock: \(s.now_local)\(s.offset_days > 0 ? " (+\(s.offset_days.formatted()) days)" : ""). Run the sweep before skipping past Monday; a new week resets spending.")
            }
        }
        .disabled(bank.isBusy)
    }
}

// MARK: - Server address

struct ServerSection: View {
    @Environment(BankStore.self) private var bank

    var body: some View {
        @Bindable var bank = bank
        Section {
            TextField("Server", text: $bank.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
        } header: {
            Text("DigiFridgey server")
        } footer: {
            Text("The Simulator can use localhost. On a real iPhone, use your Mac's Wi-Fi address, e.g. http://192.168.1.20:8010.")
        }
    }
}
