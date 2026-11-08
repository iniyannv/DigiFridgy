import SwiftUI
import UIKit
import SafariServices

// MARK: - Toasts (no silent failures)

struct ToastOverlay: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// How far the toast has been dragged; past the threshold it's dismissed.
    @State private var drag: CGSize = .zero
    /// Reports where the toast is on screen (nil when hidden), so its window only takes touches there.
    var reportFrame: ((CGRect?) -> Void)?

    /// Seconds before a toast goes away on its own (Undo gets a little longer to reach).
    static func lifetime(for toast: Toast) -> Double {
        toast.isError ? 6 : toast.actionTitle != nil ? 5 : 3.5
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = app.toast {
                HStack(spacing: 12) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Tone.warning.color : Tone.success.color)
                        .accessibilityHidden(true)
                    Text(toast.message)
                        .font(.subheadline)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) {
                            action()
                            dismiss(toast)
                        }
                        .font(.subheadline.bold())
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    Button {
                        dismiss(toast)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            // The whole 44pt square is tappable, not just the glyph.
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
                // Mostly opaque, so toolbar buttons behind it don't show through the glass.
                .background(Color(uiColor: .systemBackground).opacity(0.75), in: .capsule)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal)
                .padding(.top, 8)
                .offset(x: drag.width, y: min(0, drag.height))
                .opacity(1 - min(0.6, (abs(drag.width) + max(0, -drag.height)) / 250))
                .simultaneousGesture(
                    // Swipe up or sideways to clear it.
                    DragGesture(minimumDistance: 8)
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let flung = abs(value.predictedEndTranslation.width) > 120 || value.predictedEndTranslation.height < -40
                            if flung || abs(value.translation.width) > 80 || value.translation.height < -24 {
                                dismiss(toast)
                            } else {
                                withAnimation(.spring(duration: 0.3)) { drag = .zero }
                            }
                        }
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reportFrame?($0) }
                .onDisappear { reportFrame?(nil) }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Dismiss") { dismiss(toast) }
                .task(id: toast.id) {
                    AccessibilityNotification.Announcement(toast.message).post()
                    // VoiceOver users dismiss toasts themselves, so an Undo can't vanish before it's reached.
                    guard !voiceOver else { return }
                    try? await Task.sleep(for: .seconds(Self.lifetime(for: toast)))
                    guard !Task.isCancelled else { return }
                    dismiss(toast)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast?.id)
        .onChange(of: app.toast?.id) { drag = .zero }
    }

    private func dismiss(_ toast: Toast) {
        if app.toast?.id == toast.id { app.toast = nil }
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }

    /// Shows the app's toasts in a window of their own, above navigation bars, the tab bar and sheets.
    /// (Drawn inside the app's window, the navigation bar sat on top of the toast and took its taps.)
    func toastWindow(_ app: AppState) -> some View { background(ToastWindowInstaller(app: app)) }
}

/// A window that only takes touches on the toast; everything else falls through to the app.
final class ToastPassThroughWindow: UIWindow {
    var toastFrame: CGRect?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let toastFrame, toastFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
final class ToastWindowController {
    static let shared = ToastWindowController()
    private var window: ToastPassThroughWindow?

    func install(in scene: UIWindowScene, app: AppState) {
        guard window?.windowScene !== scene else { return }
        let window = ToastPassThroughWindow(windowScene: scene)
        // Above the app window (and its sheets), below system alerts and the keyboard.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ToastHost(window: window).environment(app))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

private struct ToastHost: View {
    let window: ToastPassThroughWindow

    var body: some View {
        Color.clear
            .modifier(ToastOverlay(reportFrame: { [weak window] frame in window?.toastFrame = frame }))
    }
}

private struct ToastWindowInstaller: UIViewRepresentable {
    let app: AppState

    func makeUIView(context: Context) -> InstallerView { InstallerView(app: app) }
    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        let app: AppState

        init(app: AppState) {
            self.app = app
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { ToastWindowController.shared.install(in: scene, app: app) }
        }
    }
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
        case "pantry": "🥫"
        case "snacks": "🍫"
        default: "🛒"
        }
    }
}

struct ItemThumbnail: View {
    var item: FridgeItem
    var size: CGFloat = 44

    var body: some View {
        CategoryThumbnail(categoryID: item.category, imageURL: item.imageURL, size: size)
    }
}

/// Product photo when there is one, else the food type's emoji, in a rounded tile. Shared by fridge and
/// shopping-list rows so both lists look the same.
struct CategoryThumbnail: View {
    var categoryID: String
    var imageURL: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = imageURL.flatMap(URL.init(string:)) {
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
        .accessibilityHidden(true)
    }

    private var emoji: some View {
        Text(CategoryStyle.emoji(for: categoryID))
            .font(.system(size: size * 0.55))
            .accessibilityHidden(true)
    }
}

/// Bottom bar of actions for the selected rows in a list's select mode.
struct SelectionActionBar<Actions: View>: View {
    var count: Int
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(count == 0 ? "Select items" : "\(count) selected")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .lineLimit(1)
                .fixedSize()
                .disabled(count == 0)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        .controlSize(.regular)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Expiry label ("Est." when estimated)

struct ExpiryLabel: View {
    var item: FridgeItem

    var body: some View {
        let days = item.daysUntilExpiry()
        HStack(spacing: 4) {
            if item.expiryIsEstimated {
                StatusChip(text: "Est.", tone: .neutral)
            }
            Text(item.expiresAt, format: .dateTime.month(.abbreviated).day())
            Text("·")
            Text(Self.relative(days))
        }
        .font(.caption)
        .foregroundStyle(item.urgency().color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(item, days: days))
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

    /// Full words for VoiceOver ("Estimated expiry February 5, in 89 days").
    static func spoken(_ item: FridgeItem, days: Int) -> String {
        let date = item.expiresAt.formatted(.dateTime.month(.wide).day())
        let when: String = switch days {
        case ..<(-1): "expired \(-days) days ago"
        case -1: "expired yesterday"
        case 0: "expires today"
        case 1: "expires tomorrow"
        default: "in \(days) days"
        }
        return "\(item.expiryIsEstimated ? "Estimated expiry" : "Expires") \(date), \(when)"
    }
}

extension ExpiryUrgency {
    /// Text colour: contrast-safe on grouped backgrounds.
    var color: Color {
        switch self {
        case .expired: Tone.danger.color
        case .soon: Tone.warning.color
        case .ok: .secondary
        }
    }

    /// Fill colour for dots and bars.
    var tint: Color {
        switch self {
        case .expired: .red
        case .soon: .orange
        case .ok: .green
        }
    }
}

extension RecallFlag {
    /// Confirmed recalls are red; "possible" matches are amber so they don't read as certain.
    var tone: Tone { confidence == .confirmed ? .danger : .warning }
}

// MARK: - Design tokens

/// Semantic status colours. Text variants are darkened in light mode so orange and green text
/// clear 4.5:1 on white and grouped backgrounds; dark mode uses the brighter system colours.
enum Tone: Sendable {
    case success, warning, danger, info, neutral

    var color: Color {
        switch self {
        case .success: Color(light: UIColor(red: 0.08, green: 0.50, blue: 0.20, alpha: 1), dark: .systemGreen)
        case .warning: Color(light: UIColor(red: 0.70, green: 0.33, blue: 0.00, alpha: 1), dark: .systemOrange)
        case .danger: Color(light: UIColor(red: 0.78, green: 0.12, blue: 0.10, alpha: 1), dark: .systemRed)
        case .info: Color(light: UIColor(red: 0.00, green: 0.40, blue: 0.80, alpha: 1), dark: .systemBlue)
        case .neutral: .secondary
        }
    }

    /// Soft background for chips and banners.
    var fill: Color {
        switch self {
        case .success: .green.opacity(0.16)
        case .warning: .orange.opacity(0.18)
        case .danger: .red.opacity(0.14)
        case .info: .blue.opacity(0.14)
        case .neutral: Color(uiColor: .tertiarySystemFill)
        }
    }
}

enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// One chip for every small status label (Est., Sample price, Live, allergens, "Sam's getting it").
struct StatusChip: View {
    var text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tone.fill, in: .capsule)
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
    }
}

/// Filled text field used outside of Forms (onboarding, manual barcode entry).
struct FilledFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(minHeight: 44)
            .background(.fill.tertiary, in: .rect(cornerRadius: Radius.medium))
    }
}

extension View {
    func filledField() -> some View { modifier(FilledFieldStyle()) }
}

// MARK: - Empty states

/// Every zero-data screen: what this is, why it matters, and one thing to do next.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var primaryTitle: String?
    var primary: (() -> Void)?
    var secondaryTitle: String?
    var secondary: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let primaryTitle, let primary {
                Button(primaryTitle, action: primary)
                    .buttonStyle(.borderedProminent)
            }
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary)
                    .buttonStyle(.bordered)
            }
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
        StatusChip(text: "Sample price", tone: .warning)
    }
}

extension DateFormatter {
    /// "Nov 8" — shared so lists don't build a formatter per row.
    static let shortMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
