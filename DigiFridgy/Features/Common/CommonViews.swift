import SwiftUI
import UIKit
import SafariServices

// MARK: - Toasts (no silent failures)

struct ToastOverlay: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = app.toast {
                HStack(spacing: 12) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? .orange : .green)
                    Text(toast.message)
                        .font(.subheadline)
                        .lineLimit(3)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) {
                            action()
                            app.toast = nil
                        }
                        .font(.subheadline.bold())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { app.toast = nil }
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(toast.actionTitle == nil ? 3.5 : 6))
                    if app.toast?.id == toast.id { app.toast = nil }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast?.id)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

// MARK: - Category visuals

enum CategoryStyle {
    static func emoji(for categoryID: String) -> String {
        switch categoryID {
        case "milk", "cream": "🥛"
        case "plant_milk": "🌰"
        case "butter": "🧈"
        case "yogurt", "sour_cream", "cottage_cheese": "🥣"
        case "cream_cheese", "hard_cheese", "soft_cheese", "shredded_cheese": "🧀"
        case "ice_cream": "🍨"
        case "eggs": "🥚"
        case "chicken": "🍗"
        case "ground_meat", "beef", "pork": "🥩"
        case "sausage", "hot_dogs": "🌭"
        case "bacon": "🥓"
        case "deli_meat": "🥪"
        case "fish", "smoked_fish": "🐟"
        case "shellfish": "🦐"
        case "tofu": "🫘"
        case "hummus", "salsa", "condiments", "mayonnaise", "pasta_sauce", "pickles": "🫙"
        case "juice": "🧃"
        case "leafy_greens": "🥬"
        case "berries": "🍓"
        case "grapes": "🍇"
        case "apples": "🍎"
        case "citrus": "🍋"
        case "bananas": "🍌"
        case "avocado": "🥑"
        case "tomatoes": "🍅"
        case "carrots": "🥕"
        case "broccoli": "🥦"
        case "peppers": "🫑"
        case "cucumbers": "🥒"
        case "mushrooms": "🍄"
        case "onions": "🧅"
        case "potatoes": "🥔"
        case "herbs", "celery": "🌿"
        case "corn": "🌽"
        case "bread", "dough": "🍞"
        case "tortillas": "🫓"
        case "fresh_pasta", "prepared_meals": "🍝"
        case "pizza": "🍕"
        case "beverages": "🥤"
        case "snacks": "🍫"
        default: "🛒"
        }
    }
}

struct ItemThumbnail: View {
    var item: FridgeItem
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = item.imageURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    emoji
                }
            } else {
                emoji
            }
        }
        .frame(width: size, height: size)
        .background(.fill.tertiary, in: .rect(cornerRadius: size * 0.25))
        .clipShape(.rect(cornerRadius: size * 0.25))
    }

    private var emoji: some View {
        Text(CategoryStyle.emoji(for: item.category)).font(.system(size: size * 0.55))
    }
}

// MARK: - Expiry label ("Est." when estimated)

struct ExpiryLabel: View {
    var item: FridgeItem

    var body: some View {
        let days = item.daysUntilExpiry()
        HStack(spacing: 4) {
            if item.expiryIsEstimated {
                Text("Est.").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.fill.secondary, in: .capsule)
            }
            Text(item.expiresAt, format: .dateTime.month(.abbreviated).day())
            Text("·")
            Text(Self.relative(days))
        }
        .font(.caption)
        .foregroundStyle(item.urgency().color)
    }

    static func relative(_ days: Int) -> String {
        switch days {
        case ..<(-1): "expired \(-days)d ago"
        case -1: "expired yesterday"
        case 0: "today"
        case 1: "tomorrow"
        default: "in \(days)d"
        }
    }
}

extension ExpiryUrgency {
    var color: Color {
        switch self {
        case .expired: .red
        case .soon: .orange
        case .ok: .secondary
        }
    }

    var tint: Color {
        switch self {
        case .expired: .red
        case .soon: .orange
        case .ok: .green
        }
    }
}

// MARK: - Safari

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Misc

extension Double {
    var usd: String { formatted(.currency(code: "USD")) }
}

struct SampleBadge: View {
    var body: some View {
        Text("Sample price")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.yellow.opacity(0.25), in: .capsule)
            .foregroundStyle(.orange)
    }
}
