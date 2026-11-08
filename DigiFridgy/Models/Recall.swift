import Foundation

nonisolated struct Recall: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var reason: String
    var productDescription: String
    var codeInfo: String
    var firm: String
    var date: Date
    var classification: String?
    var url: String

    var asFlag: RecallFlag { flag(confidence: .confirmed) }

    func flag(confidence: RecallConfidence) -> RecallFlag {
        RecallFlag(recallId: id, reason: reason, date: date, url: url, confidence: confidence)
    }
}

/// Info returned by a product lookup (barcode or name).
nonisolated struct ProductInfo: Hashable, Sendable {
    var barcode: String?
    var name: String
    var brand: String?
    var categoryTags: [String]
    var imageURL: String?
    var nutrition: Nutrition?
    var nutriScore: String?
    var allergenTags: [String]
}
