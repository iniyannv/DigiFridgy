import SwiftUI

/// Questions the iMessage assistant asked the household ("Add these 6 items from your photo?"), live from
/// SpacetimeDB. Answer here or by text; the first answer wins and the other side updates.
struct ApprovalsSection: View {
    @Environment(AppState.self) private var app
    @State private var confirming: Approval?
    @State private var answered = 0

    var body: some View {
        Section {
            ForEach(app.approvals) { approval in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: approval.money ? "dollarsign.circle.fill" : "questionmark.bubble.fill")
                            .foregroundStyle(approval.money ? Tone.success.color : Tone.info.color)
                            .accessibilityHidden(true)
                        Text(approval.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(approval.createdAt, style: .relative)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !approval.detail.isEmpty {
                        Text(approval.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack(spacing: 10) {
                        Button {
                            if approval.money { confirming = approval } else { answer(approval, yes: true) }
                        } label: {
                            Text("Yes").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            answer(approval, yes: false)
                        } label: {
                            Text("No").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
            }
        } header: {
            Label("Your fridge is asking", systemImage: "message.badge")
        } footer: {
            Text(app.approvals.contains(where: \.money)
                 ? "Your fridge's iMessage assistant asks before adding items or moving money. Answer here or by text; money only moves when the account holder says yes."
                 : "Your fridge's iMessage assistant asks before adding items. Answer here or by text.")
        }
        .sensoryFeedback(.success, trigger: answered)
        .confirmationDialog(
            confirming?.title ?? "Move money?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { approval in
            Button("Yes, move the money") { answer(approval, yes: true) }
            Button("Cancel", role: .cancel) {}
        } message: { approval in
            Text(approval.detail.isEmpty ? "This moves money between your accounts." : approval.detail)
        }
    }

    private func answer(_ approval: Approval, yes: Bool) {
        answered += 1
        app.answer(approval, yes: yes)
    }
}
