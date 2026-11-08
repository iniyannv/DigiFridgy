import SwiftUI

/// Questions the iMessage agent asked the household ("Add these 6 items from your photo?"), live from
/// SpacetimeDB. Answer here or by text; the first answer wins and the other side updates.
struct ApprovalsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            ForEach(app.approvals) { approval in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: approval.money ? "dollarsign.circle.fill" : "questionmark.bubble.fill")
                            .foregroundStyle(approval.money ? .green : .blue)
                        Text(approval.title).font(.subheadline.weight(.semibold))
                    }
                    if !approval.detail.isEmpty {
                        Text(approval.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack {
                        Button("Yes") { app.answer(approval, yes: true) }
                            .buttonStyle(.glassProminent).controlSize(.small)
                        Button("Not now") { app.answer(approval, yes: false) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                        Text(approval.createdAt, style: .relative)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Waiting on a yes", systemImage: "message.badge")
        } footer: {
            Text(app.approvals.contains(where: \.money)
                 ? "Also asked over iMessage; answer in either place. Money only moves when the account holder says yes."
                 : "Also asked over iMessage; answer in either place.")
        }
    }
}
