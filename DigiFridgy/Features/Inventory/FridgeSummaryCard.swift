import SwiftUI
import Charts

/// Whole-fridge summary: totals, Nutri-Score distribution, allergen flags, expiring this week.
struct FridgeSummaryCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize

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
        let expiringItems = items.filter { (0...7).contains($0.daysUntilExpiry()) }
        let expiringThisWeek = expiringItems.count
        // Estimated dates are approximate, so the count is too.
        let expiringValue = expiringItems.contains(where: \.expiryIsEstimated) ? "~\(expiringThisWeek)" : "\(expiringThisWeek)"
        let allergenFlags = items.filter { !$0.allergenHits(for: app.userAllergens).isEmpty }.count
        let totalUnits = items.reduce(0) { $0 + $1.count }
        let scored = items.filter { $0.nutriScore != nil }.count

        VStack(alignment: .leading, spacing: 14) {
            let stats = Group {
                stat(value: "\(items.count)", label: items.count == 1 ? "item" : "items",
                     spoken: "\(items.count) \(items.count == 1 ? "item" : "items"), \(totalUnits) \(totalUnits == 1 ? "unit" : "units")",
                     tone: nil)
                stat(value: expiringValue, label: "use this week",
                     spoken: "\(expiringThisWeek) expiring this week\(expiringValue.hasPrefix("~") ? ", including estimates" : "")",
                     tone: expiringThisWeek > 0 ? .warning : nil)
                stat(value: "\(allergenFlags)", label: allergenFlags == 1 ? "allergen flag" : "allergen flags",
                     spoken: "\(allergenFlags) allergen \(allergenFlags == 1 ? "flag" : "flags")",
                     tone: allergenFlags > 0 ? .danger : nil)
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { stats }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) { stats }
            }

            // A distribution needs a few scored items before it says anything.
            if scored >= 3 {
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
                    .frame(height: 64)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Nutri-Score")
                .accessibilityValue(gradeCounts.filter { $0.count > 0 }
                    .map { "\($0.grade == "?" ? "unscored" : $0.grade): \($0.count)" }.joined(separator: ", "))
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(value: String, label: String, spoken: String, tone: Tone?) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
                .foregroundStyle(tone?.color ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
