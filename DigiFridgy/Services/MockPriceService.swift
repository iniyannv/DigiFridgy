import Foundation

/// Deterministic sample prices for chains without a public price API.
/// Same UPC + chain always yields the same price (±20% around the reference price).
/// Every price produced here must be shown with a "Sample price" badge.
nonisolated struct MockPriceService: Sendable {
    func price(upc: String?, name: String, chain: String, referencePrice: Double) -> Double {
        let key = (upc.map(Barcode.normalize) ?? name.lowercased()) + "|" + chain.lowercased()
        let fraction = Double(Self.fnv1a(key) % 10_000) / 10_000          // 0..<1
        let raw = referencePrice * (0.8 + 0.4 * fraction)                 // ±20%
        return Self.retailRound(raw)
    }

    /// Reference price when there is no live Kroger price: the category baseline.
    func referencePrice(categoryID: String, shelfLife: ShelfLifeService = .shared) -> Double {
        shelfLife.category(id: categoryID)?.baselinePrice ?? 3.49
    }

    /// 3.4312 → 3.49 (prices end in 9).
    static func retailRound(_ value: Double) -> Double {
        let tenths = (max(value, 0.2) * 10).rounded(.down) / 10
        return ((tenths + 0.09) * 100).rounded() / 100
    }

    /// Stable across launches (Swift's `hashValue` is randomly seeded).
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
