import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = true
    @State private var isWorking = false
    @State private var showEmail = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "refrigerator.fill")
                            .font(.system(size: heroSize))
                            .foregroundStyle(.tint)
                            .padding(24)
                            .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .circle)
                            .accessibilityHidden(true)
                        Text("DigiFridgy")
                            .font(.largeTitle.bold())
                        Text("Know what's in your fridge, use it before it goes bad, and spend less on groceries.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow(symbol: "barcode.viewfinder", text: "Scan a barcode to add food")
                        FeatureRow(symbol: "calendar.badge.clock", text: "A heads-up before things expire")
                        FeatureRow(symbol: "fork.knife", text: "Recipes that use expiring food first")
                        FeatureRow(symbol: "person.2.fill", text: "One fridge shared with your household")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quinary, in: .rect(cornerRadius: Radius.large))

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                isWorking = true
                                await app.signInAnonymously()
                                isWorking = false
                            }
                        } label: {
                            Text("Start without an account").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        Text(app.services.auth.supportsEmail
                             ? "Your fridge is saved on this iPhone. You can add an email later to use it on other devices."
                             : "Your fridge is saved on this iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if app.services.auth.supportsEmail {
                            Button {
                                withAnimation { showEmail.toggle() }
                            } label: {
                                Text("Sign in or sign up with email").frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                        }
                    }

                    if showEmail {
                        emailForm.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if app.services.isMock {
                        Label("Offline demo: everything stays on this device.", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView().controlSize(.large) } }
        }
    }

    private var emailForm: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $createAccount) {
                Text("Create account").tag(true)
                Text("Sign in").tag(false)
            }
            .pickerStyle(.segmented)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .filledField()
            SecureField("Password (6+ characters)", text: $password)
                .textContentType(createAccount ? .newPassword : .password)
                .filledField()

            Button {
                Task {
                    isWorking = true
                    await app.signIn(email: email, password: password, createAccount: createAccount)
                    isWorking = false
                }
            } label: {
                Text(createAccount ? "Create account" : "Sign in").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(!email.contains("@") || password.count < 6)
        }
    }
}

private struct FeatureRow: View {
    var symbol: String
    var text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
        }
    }
}

struct HouseholdSetupView: View {
    @Environment(AppState.self) private var app
    @State private var householdName = ""
    @State private var code = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A household is one shared fridge. Start your own, or join someone else's with their code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }

                Section {
                    TextField("Name (e.g. Our Fridge)", text: $householdName)
                    Button("Create household") {
                        Task {
                            isWorking = true
                            let name = householdName.trimmingCharacters(in: .whitespaces)
                            await app.createHousehold(name: name.isEmpty ? "Our Fridge" : name)
                            isWorking = false
                        }
                    }
                    .bold()
                } header: {
                    Text("Start a new fridge")
                } footer: {
                    Text("Just you? Start one anyway. You'll get a 6-character code to invite roommates or family any time.")
                }

                Section {
                    TextField("Invite code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .onChange(of: code) { _, new in code = String(new.uppercased().prefix(6)) }
                    Button("Join household") {
                        Task {
                            isWorking = true
                            await app.joinHousehold(code: code)
                            isWorking = false
                        }
                    }
                    .disabled(code.count != 6)
                } header: {
                    Text("Join an existing fridge")
                }

                // A guest who signs out here loses their identity for good, so only email users see it.
                if app.user?.isAnonymous == false {
                    Section {
                        Button("Sign out", role: .destructive) { app.signOut() }
                    }
                }
            }
            .navigationTitle("Your household")
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView().controlSize(.large) } }
        }
    }
}
