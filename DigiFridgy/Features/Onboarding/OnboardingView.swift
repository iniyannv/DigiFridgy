import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = true
    @State private var isWorking = false
    @State private var showEmail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "refrigerator.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .padding(24)
                            .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .circle)
                        Text("DigiFridgy")
                            .font(.largeTitle.bold())
                        Text("Scan groceries, see what expires first, cook with it, and find the cheapest store.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow(symbol: "barcode.viewfinder", text: "Barcode & receipt scanning")
                        FeatureRow(symbol: "calendar.badge.clock", text: "Estimated expiry, reminders")
                        FeatureRow(symbol: "fork.knife", text: "Recipes that use expiring food first")
                        FeatureRow(symbol: "person.2.fill", text: "One shared fridge for the household")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quinary, in: .rect(cornerRadius: 20))

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                isWorking = true
                                await app.signInAnonymously()
                                isWorking = false
                            }
                        } label: {
                            Text("Try it").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)

                        Button {
                            withAnimation { showEmail.toggle() }
                        } label: {
                            Text("Use email instead").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }

                    if showEmail {
                        emailForm.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if app.services.isMock {
                        Label("Offline demo mode — data stays on this device.", systemImage: "wifi.slash")
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
                .padding(12)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            SecureField("Password (6+ characters)", text: $password)
                .textContentType(createAccount ? .newPassword : .password)
                .padding(12)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))

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
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28)
        }
    }
}

struct HouseholdSetupView: View {
    @Environment(AppState.self) private var app
    @State private var householdName = "Our Fridge"
    @State private var code = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Household name", text: $householdName)
                    Button("Create household") {
                        Task {
                            isWorking = true
                            await app.createHousehold(name: householdName)
                            isWorking = false
                        }
                    }
                    .bold()
                } header: {
                    Text("Start a new fridge")
                } footer: {
                    Text("You'll get a 6-character invite code to share with roommates or family.")
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

                Section {
                    Button("Sign out", role: .destructive) { app.signOut() }
                }
            }
            .navigationTitle("Your household")
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView().controlSize(.large) } }
        }
    }
}
