import SwiftUI

struct RecipeCard: View {
    var scored: ScoredRecipe
    var isSaved = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RecipeImage(urlString: scored.recipe.imageURL)
                .frame(width: 84, height: 84)
                .clipShape(.rect(cornerRadius: Radius.medium))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.displayTitle(scored.recipe.title)).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    if isSaved {
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                }
                if !scored.uses.isEmpty {
                    usesText.font(.subheadline).lineLimit(2)
                }
                missingText.font(.caption).lineLimit(1)
                if let swaps = scored.recipe.swaps, !swaps.isEmpty {
                    Self.swapText(swaps).font(.caption).lineLimit(3)
                }
                // Time and calories always show; the expiring chip drops to its own line when space is short.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        metaItems
                        Spacer(minLength: 4)
                        expiringChip
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) { metaItems }
                        expiringChip
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            StatusChip(text: scored.recipe.difficulty.label, tone: scored.recipe.difficulty.tone).fixedSize()
                            timeLabel
                        }
                        caloriesLabel
                        expiringChip
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Substituting − chicken breast + extra-firm tofu": the removed ingredient in red, its replacement in green.
    static func swapText(_ swaps: [IngredientSwap]) -> Text {
        var result = Text("Substituting ").foregroundStyle(.secondary)
        for (index, swap) in swaps.enumerated() {
            let removed = Text("− \(swap.original)").foregroundStyle(Tone.danger.color).bold()
            let added = Text(" + \(swap.replacement)").foregroundStyle(Tone.success.color)
            result = Text("\(result)\(index > 0 ? Text(", ") : Text(""))\(removed)\(added)")
        }
        return result
    }

    /// Same wording on every card: "Uses 2 expiring".
    static func expiringText(_ count: Int) -> String { "Uses \(count) expiring" }

    @ViewBuilder
    private var metaItems: some View {
        StatusChip(text: scored.recipe.difficulty.label, tone: scored.recipe.difficulty.tone).fixedSize()
        timeLabel
        caloriesLabel
    }

    private var timeLabel: some View {
        Label(scored.recipe.timeText, systemImage: "clock").fixedSize()
    }

    private var caloriesLabel: some View {
        Label(scored.recipe.caloriesText, systemImage: "flame").fixedSize()
    }

    @ViewBuilder
    private var expiringChip: some View {
        if scored.expiringCount > 0 {
            StatusChip(text: Self.expiringText(scored.expiringCount), tone: .success).fixedSize()
        }
    }

    /// "Missing: bacon, balsamic vinegar +2", or a reassuring line when nothing is missing.
    @ViewBuilder
    private var missingText: some View {
        if scored.missing.isEmpty {
            if !scored.uses.isEmpty {
                Label("You have everything", systemImage: "checkmark.circle.fill")
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(Tone.success.color)
            }
        } else {
            let extra = scored.missing.count - 3
            Text("Missing: \(scored.missing.prefix(3).joined(separator: ", "))\(extra > 0 ? " +\(extra)" : "")")
                .foregroundStyle(.secondary)
        }
    }

    /// "Uses spinach, chicken breast, butter": expiring-soon items bold in orange.
    private var usesText: Text {
        var result = Text("Uses ").foregroundStyle(.secondary)
        for (index, match) in scored.uses.enumerated() {
            let name = match.isExpiringSoon
                ? Text(match.itemName).foregroundStyle(Tone.warning.color).bold()
                : Text(match.itemName)
            result = Text("\(result)\(index > 0 ? ", " : "")\(name)")
        }
        return result
    }

    private var accessibilityText: String {
        var parts = [Self.displayTitle(scored.recipe.title)]
        if isSaved { parts.append("saved") }
        parts.append(scored.recipe.difficulty.label.lowercased())
        if !scored.uses.isEmpty { parts.append("uses \(scored.uses.map(\.itemName).joined(separator: ", "))") }
        if scored.expiringCount > 0 { parts.append(Self.expiringText(scored.expiringCount).lowercased()) }
        parts.append(scored.missing.isEmpty ? "nothing missing" : "missing \(scored.missing.count)")
        if let swap = scored.recipe.swapSummary { parts.append(swap) }
        let recipe = scored.recipe
        parts.append("\(recipe.isTimeEstimated ? "about " : "")\(recipe.displayMinutes) minutes")
        parts.append("\(recipe.isCaloriesEstimated ? "about " : "")\(recipe.displayCalories) calories per serving")
        return parts.joined(separator: ", ")
    }

    /// Cleans up source titles: shouting ("INSTANT CHOCOLATE MOUSSE") becomes title case, and SEO suffixes
    /// like "Recipe 5" are dropped.
    static func displayTitle(_ title: String) -> String {
        var title = title.replacingOccurrences(of: #"\s+recipe\s*\d*\s*$"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return "Recipe" }
        // Mostly capitals (a site name tacked on in mixed case still counts).
        let letters = title.filter(\.isLetter)
        let upper = letters.filter(\.isUppercase).count
        if letters.count >= 4, Double(upper) / Double(letters.count) > 0.7 {
            title = title.localizedCapitalized
        }
        return title
    }
}

/// Icon + text with tight spacing for metadata rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// A recipe photo that falls back to an icon when there is none or it fails to load
/// (Edamam image links expire after an hour).
struct RecipeImage: View {
    var urlString: String?
    var iconFont: Font = .title

    var body: some View {
        if let url = urlString.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: fallback
                default: Rectangle().fill(.fill.tertiary)
                }
            }
            .accessibilityHidden(true)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: "fork.knife")
            .font(iconFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.tertiary)
            .accessibilityHidden(true)
    }
}
