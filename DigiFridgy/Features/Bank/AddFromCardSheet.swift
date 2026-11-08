import SwiftUI

/// "+ → Add from card": products from recent card purchases, picked like a scanned receipt.
struct AddFromCardSheet: View {
    @Environment(BankStore.self) private var bank
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var purchases: [CardPurchase] = []
    @State private var selected: [String: Set<Int>] = [:]
    @State private var loading = true
    @State private var error: String?

    private var selectedCount: Int { selected.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("Couldn't load card purchases", systemImage: "creditcard.trianglebadge.exclamationmark",
                                           description: Text(error))
                } else if purchases.isEmpty {
                    ContentUnavailableView("No grocery purchases yet", systemImage: "creditcard",
                                           description: Text("Grocery purchases on your card from the last two weeks show up here."))
                } else {
                    list
                }
            }
            .navigationTitle("Add from card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedCount == 0 ? "Add" : "Add \(selectedCount)", action: add)
                        .disabled(selectedCount == 0 || bank.isBusy)
                }
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            Section {
                Text("Pick what actually went in your fridge. Items already added are checked off.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(purchases) { p in
                Section {
                    ForEach(p.lines) { line in row(p, line) }
                } header: {
                    HStack {
                        Text(p.merchant)
                        Spacer()
                        Text("\(shortDate(p.date)) · \(p.amount.formatted(.currency(code: "USD")))")
                    }
                } footer: {
                    if p.pendingCount > 0 {
                        let all = Set(p.lines.filter { !$0.isAdded }.map(\.index))
                        Button(selected[p.id] == all ? "Deselect all" : "Select all \(all.count)") {
                            selected[p.id] = selected[p.id] == all ? [] : all
                        }
                        .font(.footnote.bold())
                    }
                }
            }
        }
    }

    private func row(_ p: CardPurchase, _ line: CardLine) -> some View {
        let isOn = selected[p.id, default: []].contains(line.index)
        return Button {
            guard !line.isAdded else { return }
            var set = selected[p.id, default: []]
            if isOn { set.remove(line.index) } else { set.insert(line.index) }
            selected[p.id] = set
        } label: {
            HStack(spacing: 12) {
                Image(systemName: line.isAdded ? "checkmark.circle.fill" : (isOn ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(line.isAdded ? Color.secondary : (isOn ? Color.accentColor : Color.secondary))
                    .font(.title3)
                Text(line.emoji)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name + (line.qty > 1 ? " ×\(line.qty)" : ""))
                        .foregroundStyle(line.isAdded ? .secondary : .primary)
                    Text(line.isAdded ? "In your fridge" : "Keeps about \(line.shelf_life_days) days")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(line.total.formatted(.currency(code: "USD"))).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(line.isAdded)
    }

    private func shortDate(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            purchases = try await bank.cardPurchases()
            // Start with everything not yet added selected, like a scanned receipt.
            for p in purchases {
                selected[p.id] = Set(p.lines.filter { !$0.isAdded }.map(\.index))
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        Task {
            var messages: [String] = []
            do {
                for p in purchases {
                    let lines = selected[p.id, default: []]
                    if !lines.isEmpty { messages.append(try await bank.addFromCard(p, lines: lines)) }
                }
                app.toast = Toast(message: messages.joined(separator: " "))
                dismiss()
            } catch {
                app.toast = Toast(message: error.localizedDescription, isError: true)
            }
        }
    }
}
