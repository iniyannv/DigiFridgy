import Foundation

/// The user's corrections to a scanned product (name, brand, category, nutrition), keyed by barcode.
/// Applied on top of the Open Food Facts result every time that barcode is scanned again.
nonisolated struct ProductOverride: Codable, Hashable, Sendable {
    var barcode: String
    var name: String
    var brand: String?
    var category: String
    var nutrition: Nutrition?
    var updatedAt: Date

    init(item: FridgeItem, barcode: String) {
        self.barcode = barcode
        name = item.name
        brand = item.brand
        category = item.category
        nutrition = item.nutrition
        updatedAt = .now
    }

    /// Copies the corrected fields onto a freshly looked-up item.
    func apply(to item: inout FridgeItem) {
        item.name = name
        item.brand = brand
        item.category = category
        item.nutrition = nutrition
    }
}

/// On-device JSON file in Application Support. Survives relaunches; not shared with other household members.
final class ProductOverrideStore {
    static let shared = ProductOverrideStore()

    private var overrides: [String: ProductOverride]
    private let fileURL: URL?

    /// `fileURL == nil` keeps everything in memory (tests).
    init(fileURL: URL? = ProductOverrideStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ProductOverride].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("product-overrides.json")
    }

    func override(forBarcode barcode: String) -> ProductOverride? {
        overrides[Barcode.normalize(barcode)]
    }

    /// Remembers the item's current name / brand / category / nutrition for its barcode.
    func remember(_ item: FridgeItem) {
        guard let barcode = item.normalizedBarcode, !barcode.isEmpty else { return }
        overrides[barcode] = ProductOverride(item: item, barcode: barcode)
        persist()
    }

    func forget(barcode: String) {
        overrides[Barcode.normalize(barcode)] = nil
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(overrides).write(to: fileURL, options: .atomic)
        } catch {
            print("ProductOverrideStore: couldn't save overrides: \(error)")
        }
    }
}
