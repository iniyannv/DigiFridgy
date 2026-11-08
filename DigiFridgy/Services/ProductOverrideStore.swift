import Foundation
import os

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
    private static let log = Logger(subsystem: "DigiFridgy", category: "overrides")

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
    /// Returns the error when the corrections couldn't be written to disk (they still apply this session).
    @discardableResult
    func remember(_ item: FridgeItem) -> (any Error)? {
        guard let barcode = item.normalizedBarcode, !barcode.isEmpty else { return nil }
        overrides[barcode] = ProductOverride(item: item, barcode: barcode)
        return persist()
    }

    @discardableResult
    func forget(barcode: String) -> (any Error)? {
        overrides[Barcode.normalize(barcode)] = nil
        return persist()
    }

    private func persist() -> (any Error)? {
        guard let fileURL else { return nil }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(overrides).write(to: fileURL, options: .atomic)
            return nil
        } catch {
            Self.log.error("couldn't save overrides: \(error.localizedDescription, privacy: .public)")
            return error
        }
    }
}
