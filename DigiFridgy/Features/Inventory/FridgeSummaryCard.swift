import SwiftUI
import Charts

/// Whole-fridge summary: totals, Nutri-Score distribution, allergen flags, expiring this week.
struct FridgeSummaryCard: View {
    @Environment(AppState.self) private var app

    private struct GradeCount: Identifiable {
        var grade: String
        var count: Int
        var id: String { grade }
    }

    private var gradeCounts: [GradeCount] {
        let grades = ["A", "B", "C", "D", "E", "?"]
        var counts = Dictionary(uniqueKeysWithValues: grades.map { ($0, 0) })
        for item in app.items {
            let g = item.nutriScore?.uppercased() ?? "?"
            counts[grades.contains(g) ? g : "?", default: 0] += 1
        }
        return grades.map { GradeCount(grade: $0, count: counts[$0] ?? 0) }
    }

    var body: some View {
        let items = app.items
        let expiringThisWeek = items.filter { (0...7).contains($0.daysUntilExpiry()) }.count
        let allergenFlags = items.filter { !$0.allergenHits(for: app.userAllergens).isEmpty }.count
        let totalUnits = items.reduce(0) { $0 + $1.count }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                stat(value: "\(items.count)", label: "items", detail: "\(totalUnits) units", color: .primary)
                Divider().frame(height: 36)
                stat(value: "\(expiringThisWeek)", label: "expire this week", detail: nil, color: expiringThisWeek > 0 ? .orange : .primary)
                Divider().frame(height: 36)
                stat(value: "\(allergenFlags)", label: "allergen flags", detail: nil, color: allergenFlags > 0 ? .red : .primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nutri-Score").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(gradeCounts) { entry in
                    BarMark(x: .value("Grade", entry.grade), y: .value("Items", entry.count))
                        .foregroundStyle(NutriScoreBadge.color(for: entry.grade))
                        .cornerRadius(4)
                        .annotation(position: .top) {
                            if entry.count > 0 {
                                Text("\(entry.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
                .chartYAxis(.hidden)
                .frame(height: 80)
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 4)
    }

    private func stat(value: String, label: String, detail: String?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity)
    }
}
