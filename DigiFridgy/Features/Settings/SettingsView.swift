import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var showLinkEmail = false
    @State private var confirmLeave = false
    @State private var confirmSignOut = false
    @State private var mockMode = UserDefaults.standard.bool(forKey: AppServices.mockDefaultsKey)
    @State private var radius: Double = 10
    @State private var checksResult: String?
    /// The invite code is hidden until the eye is tapped (it lets anyone into the household).
    @State private var showInviteCode = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                householdSection
                BankSettingsSection()
                allergenSection

                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Store search radius")
                            Spacer()
                            Text("\(Int(radius)) mi").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $radius, in: 1...50, step: 1) { editing in
                            if !editing { app.setSearchRadius(radius) }
                        }
                    }
                } header: {
                    Text("Stores")
                }

                notificationsSection
                checksSection

                if AppServices.isDemoBuild {
                    Section {
                        NavigationLink {
                            developerPage
                        } label: {
                            Label("Developer & demo tools", systemImage: "hammer")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .expandsTabBarOnScrollUp()
            .onDisappear { showInviteCode = false }
            .onAppear { radius = app.profile?.searchRadiusMiles ?? 10 }
            .sheet(isPresented: $showLinkEmail) { LinkEmailSheet() }
            .confirmationDialog("Leave \(app.household?.name ?? "household")?", isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                Button("Leave", role: .destructive) { Task { await app.leaveHousehold() } }
            } message: {
                Text("You'll stop seeing this fridge. Other members keep it.")
            }
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section("Account") {
            if let user = app.user {
                if user.isAnonymous {
                    LabeledContent("Signed in as", value: "Guest")
                    if app.services.auth.supportsEmail {
                        Button("Save account with email", systemImage: "person.crop.circle.badge.plus") { showLinkEmail = true }
                    } else {
                        Text("Guest identity is stored on this device. Signing out loses access unless someone re-invites you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Email", value: user.email ?? "—")
                }
            }
            Button("Sign out", role: .destructive) {
                // A guest identity lives only on this phone: signing out deletes it for good.
                if app.user?.isAnonymous ?? false { confirmSignOut = true } else { app.signOut() }
            }
            .confirmationDialog("Sign out of this guest account?", isPresented: $confirmSignOut,
                                titleVisibility: .visible) {
                if app.services.auth.supportsEmail {
                    Button("Save account with email first") { showLinkEmail = true }
                }
                Button(signOutLosesHousehold ? "Sign out and lose this fridge" : "Sign out anyway", role: .destructive) {
                    app.signOut()
                }
            } message: {
                if signOutLosesHousehold {
                    Text("You're the only member of \(app.household?.name ?? "this household") and signed in as a guest. After signing out, nobody can get back into it.")
                } else {
                    Text("Guest accounts can't sign back in. You'll lose access to \(app.household?.name ?? "this household") unless someone invites you again.")
                }
            }
        }
    }

    /// A guest who is the last member can't sign back in, so the household would be orphaned.
    private var signOutLosesHousehold: Bool {
        guard let user = app.user, user.isAnonymous, let household = app.household else { return false }
        return household.memberUids.count <= 1
    }

    private var householdSection: some View {
        Section {
            if let household = app.household {
                LabeledContent("Name", value: household.name)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite code").font(.caption).foregroundStyle(.secondary)
                        Text(showInviteCode ? household.inviteCode
                                            : String(repeating: "*", count: max(household.inviteCode.count, 6)))
                            .font(.title2.monospaced().bold())
                            .textSelection(.enabled)
                            .contentTransition(.numericText())
                            .accessibilityLabel(showInviteCode ? household.inviteCode : "Hidden")
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy) { showInviteCode.toggle() }
                    } label: {
                        Label(showInviteCode ? "Hide invite code" : "Show invite code",
                              systemImage: showInviteCode ? "eye.slash" : "eye")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        UIPasteboard.general.string = household.inviteCode
                        app.showMessage("Invite code copied")
                    } label: {
                        Label("Copy invite code", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    ShareLink(item: "Join my DigiFridgy household “\(household.name)” with invite code \(household.inviteCode)") {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
                LabeledContent("Members", value: "\(household.memberUids.count)")
                Button("Leave household", role: .destructive) { confirmLeave = true }
            }
        } header: {
            Text("Household")
        } footer: {
            Text("Share the code with roommates or family. Everyone with it sees the same fridge and shopping list, live.")
        }
    }

    private var allergenSection: some View {
        Section {
            ForEach(Allergen.allCases) { allergen in
                Toggle(isOn: Binding(
                    get: { app.userAllergens.contains(allergen) },
                    set: { app.setAllergen(allergen, enabled: $0) }
                )) {
                    Label(allergen.displayName, systemImage: allergen.symbol)
                }
            }
        } header: {
            Text("My allergens")
        } footer: {
            Text("Items containing these get a warning, and recipes are filtered to exclude them.")
        }
    }

    private var checksSection: some View {
        Section {
            Button {
                Task { checksResult = await app.runChecks() }
            } label: {
                HStack {
                    Label("Check for recalls and price drops", systemImage: "arrow.clockwise.circle")
                    Spacer()
                    if app.isRunningChecks { ProgressView() }
                }
            }
            .disabled(app.isRunningChecks)
            if let summary = checksResult ?? app.lastChecksSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Recalls & price drops")
        } footer: {
            Text("DigiFridgy also checks in the background every few hours.")
        }
    }

    private var demoSection: some View {
        Section {
            Button("Seed demo household", systemImage: "wand.and.stars") { Task { await app.seedDemoHousehold() } }
            Button("Seed demo with real barcodes", systemImage: "barcode") { Task { await app.seedBarcodeDemo() } }
            Button("Simulate recall", systemImage: "exclamationmark.octagon") { Task { await app.simulateRecall() } }
            Button("Simulate price drop", systemImage: "arrow.down.circle") { Task { await app.simulatePriceDrop() } }
            Button("Test expiry notification", systemImage: "bell") { app.testExpiryNotification() }
            if AppServices.isDemoBuild {
            Toggle(isOn: $mockMode) {
                VStack(alignment: .leading) {
                    Text("Offline mock mode")
                    Text(app.services.isMock && !mockMode
                         ? "Active now — no GoogleService-Info.plist found"
                         : "Takes effect after relaunch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: mockMode) { _, value in
                UserDefaults.standard.set(value, forKey: AppServices.mockDefaultsKey)
                app.showMessage("Quit and reopen DigiFridgy to switch to \(value ? "mock" : "live") mode.")
            }
            }
        } header: {
            Text("Demo tools")
        } footer: {
            Text("Seeding adds ~14 realistic items (some expiring tomorrow, one recalled) and, if you have no allergens set, turns on sesame. The real-barcode demo adds \(BarcodeDemoData.fridge.count) real products with their UPCs and photos from Open Food Facts, plus \(BarcodeDemoData.shopping.count) barcoded shopping-list items.")
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        if app.notificationsDenied {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Reminders are off", systemImage: "bell.slash.fill").foregroundStyle(Tone.warning.color).bold()
                    Text("You won't hear about food that's about to expire, recalls, or price drops. Turn on notifications for DigiFridgy in the Settings app.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url).font(.callout)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    /// Demo controls, service diagnostics and the bank server: one tap away for the demo, out of the main list.
    private var developerPage: some View {
        Form {
            demoSection
            BankDemoSection()
            BankServerSection()
            statusSection
            Section {
                Text("API keys live in the app bundle for this hackathon demo only. A real release must proxy Edamam, Kroger and CalorieNinjas through a backend.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusSection: some View {
        Section {
            ForEach(app.services.statusLines, id: \.0) { name, live in
                LabeledContent(name) {
                    StatusChip(text: live ? "Live" : "Sample", tone: live ? .success : .warning)
                }
                .accessibilityElement(children: .combine)
            }
            if let error = app.lastError {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last error").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } header: {
            Text("Services")
        } footer: {
            Text("“Sample” services show generated demo data, never real prices or recipes from that service.")
        }
    }
}

struct LinkEmailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (6+ characters)", text: $password)
                        .textContentType(.newPassword)
                } footer: {
                    Text("Keeps your guest data and household — you'll be able to sign in on other devices.")
                }
            }
            .navigationTitle("Save account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isWorking = true
                            if await app.linkEmail(email: email, password: password) { dismiss() }
                            isWorking = false
                        }
                    }
                    .disabled(!email.contains("@") || password.count < 6 || isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
