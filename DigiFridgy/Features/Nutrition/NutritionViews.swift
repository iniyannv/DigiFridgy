import SwiftUI

/// FDA-style "Nutrition Facts" panel.
struct NutritionLabelView: View {
    var nutrition: Nutrition

    // FDA daily values (2,000 kcal diet).
    private enum DV {
        static let fat = 78.0, sodium = 2300.0, carbs = 275.0, fiber = 28.0, protein = 50.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nutrition Facts")
                .font(.title.weight(.black))
                .tracking(-0.5)
            if let serving = nutrition.servingSize {
                HStack {
                    Text("Serving size").bold()
                    Spacer()
                    Text(serving).bold()
                }
                .font(.subheadline)
                .padding(.top, 2)
            }
            bar(height: 10)
            Text("Amount per serving").font(.caption.bold())
            HStack(alignment: .firstTextBaseline) {
                Text("Calories").font(.title2.weight(.black))
                Spacer()
                Text(nutrition.kcal.map { "\(Int($0.rounded()))" } ?? "—").font(.title.weight(.black))
            }
            bar(height: 5)
            HStack {
                Spacer()
                Text("% Daily Value*").font(.caption.bold())
            }
            thin
            row("Total Fat", nutrition.fat, unit: "g", dv: DV.fat, bold: true)
            row("Sodium", nutrition.sodium, unit: "mg", dv: DV.sodium, bold: true)
            row("Total Carbohydrate", nutrition.carbs, unit: "g", dv: DV.carbs, bold: true)
            row("Dietary Fiber", nutrition.fiber, unit: "g", dv: DV.fiber, indent: true)
            row("Total Sugars", nutrition.sugar, unit: "g", dv: nil, indent: true)
            row("Protein", nutrition.protein, unit: "g", dv: nil, bold: true, last: true)
            bar(height: 10)
            Text("* The % Daily Value tells you how much a nutrient in a serving of food contributes to a daily diet. 2,000 calories a day is used for general nutrition advice.")
                .font(.caption2)
                .padding(.top, 2)
        }
        .padding(8)
        .foregroundStyle(.black)
        .background(.white)
        .overlay(Rectangle().stroke(.black, lineWidth: 1.5))
        .environment(\.colorScheme, .light)
    }

    private func bar(height: CGFloat) -> some View {
        Rectangle().fill(.black).frame(height: height).padding(.vertical, 3)
    }

    private var thin: some View { Rectangle().fill(.black).frame(height: 0.75) }

    @ViewBuilder
    private func row(_ name: String, _ value: Double?, unit: String, dv: Double?,
                     bold: Bool = false, indent: Bool = false, last: Bool = false) -> some View {
        HStack {
            let amount = value.map { " \(Self.format($0))\(unit)" } ?? " —"
            Text("\(Text(name).fontWeight(bold ? .heavy : .regular))\(amount)")
            Spacer()
            if let value, let dv {
                Text("\(Int((value / dv * 100).rounded()))%").bold()
            }
        }
        .font(.subheadline)
        .padding(.leading, indent ? 16 : 0)
        .padding(.vertical, 3)
        if !last { thin }
    }

    private static func format(_ value: Double) -> String {
        value < 10 && value.rounded() != value ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }
}

/// Nutri-Score A–E strip with the product's grade enlarged.
struct NutriScoreBadge: View {
    var grade: String?
    @ScaledMetric(relativeTo: .subheadline) private var cell: CGFloat = 28

    /// The grade is the food type's typical one, not this product's.
    var isEstimated = false

    init(grade: String?, isEstimated: Bool = false) {
        self.grade = grade
        self.isEstimated = isEstimated
    }

    init(_ score: NutriScoreGrade?) {
        self.init(grade: score?.grade, isEstimated: score?.isEstimated ?? false)
    }

    static func color(for grade: String) -> Color {
        switch grade.uppercased() {
        case "A": Color(red: 0.01, green: 0.51, blue: 0.25)
        case "B": Color(red: 0.52, green: 0.73, blue: 0.18)
        case "C": Color(red: 1.0, green: 0.80, blue: 0.01)
        case "D": Color(red: 0.93, green: 0.51, blue: 0.0)
        case "E": Color(red: 0.90, green: 0.24, blue: 0.07)
        default: .gray
        }
    }

    var body: some View {
        let selected = grade?.uppercased()
        VStack(alignment: .leading, spacing: 4) {
            Text("NUTRI-SCORE").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(["A", "B", "C", "D", "E"], id: \.self) { letter in
                    let isSelected = letter == selected
                    Text(letter)
                        .font(isSelected ? .title2.weight(.black) : .subheadline.weight(.bold))
                        // Light grades (B, C) need dark letters to stay readable.
                        .foregroundStyle(letter == "B" || letter == "C" ? .black : .white)
                        .frame(minWidth: isSelected ? cell * 1.4 : cell, minHeight: isSelected ? cell * 1.55 : cell * 1.07)
                        .background(Self.color(for: letter).opacity(selected == nil || isSelected ? 1 : 0.45),
                                    in: .rect(cornerRadius: isSelected ? 10 : 6))
                }
            }
            if selected == nil {
                Text("Not rated").font(.caption).foregroundStyle(.secondary)
            } else if isEstimated {
                Text("Typical for this food type").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nutri-Score \(selected.map { isEstimated ? "\($0), typical for this food type" : $0 } ?? "not rated")")
    }
}

/// Allergen chips; the user's own allergens are highlighted.
struct AllergenChips: View {
    var allergens: [Allergen]
    var highlighted: Set<Allergen>

    var body: some View {
        if allergens.isEmpty {
            Text("No major allergens listed").font(.subheadline).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 8) {
                ForEach(allergens) { allergen in
                    let hit = highlighted.contains(allergen)
                    HStack(spacing: 5) {
                        Image(systemName: hit ? "exclamationmark.triangle.fill" : allergen.symbol)
                        Text(allergen.displayName)
                    }
                    .font(.subheadline.weight(hit ? .semibold : .regular))
                    .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(hit ? Tone.warning.fill : Tone.neutral.fill, in: .capsule)
                        .foregroundStyle(hit ? Tone.warning.color : .primary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(hit ? "\(allergen.displayName), on your allergen list" : allergen.displayName)
                }
            }
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
