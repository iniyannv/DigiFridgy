import Foundation

/// Open Food Facts (barcode, no key) with CalorieNinjas (name, free key) as fallback.
final class LiveProductLookupService: ProductLookupService {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func lookup(barcode: String) async throws -> ProductInfo? {
        let fields = "product_name,brands,categories_tags,nutriments,nutriscore_grade,allergens_tags,image_front_small_url,serving_size"
        let url = api.url("https://world.openfoodfacts.org/api/v2/product/\(barcode).json", query: [("fields", fields)])
        do {
            let response = try await api.get(OFFProductResponse.self, from: url)
            return response.toProductInfo(barcode: barcode)
        } catch APIError.badStatus(404, _) {
            return nil
        }
    }

    func nutrition(forName name: String) async throws -> Nutrition? {
        guard Secrets.hasCalorieNinjas else { return nil }
        let url = api.url("https://api.calorieninjas.com/v1/nutrition", query: [("query", name)])
        let response = try await api.get(CalorieNinjasResponse.self, from: url,
                                         headers: ["X-Api-Key": Secrets.calorieNinjasKey])
        return response.items.first?.toNutrition()
    }
}

// MARK: - DTOs

/// Decodes numbers that may arrive as Double, Int, or numeric String (OFF is inconsistent).
nonisolated struct FlexibleDouble: Decodable, Sendable {
    var value: Double?

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

nonisolated struct OFFProductResponse: Decodable, Sendable {
    var status: Int?
    var product: OFFProduct?

    struct OFFProduct: Decodable, Sendable {
        var product_name: String?
        var brands: String?
        var categories_tags: [String]?
        var nutriments: [String: FlexibleDouble]?
        var nutriscore_grade: String?
        var allergens_tags: [String]?
        var image_front_small_url: String?
        var serving_size: String?
    }

    func toProductInfo(barcode: String) -> ProductInfo? {
        guard (status ?? 1) == 1, let product else { return nil }
        let name = product.product_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let grade = product.nutriscore_grade?.lowercased()
        return ProductInfo(
            barcode: barcode,
            name: name,
            brand: product.brands?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) },
            categoryTags: product.categories_tags ?? [],
            imageURL: product.image_front_small_url,
            nutrition: Self.nutrition(from: product.nutriments ?? [:], servingSize: product.serving_size),
            nutriScore: ["a", "b", "c", "d", "e"].contains(grade ?? "") ? grade : nil,
            allergenTags: product.allergens_tags ?? []
        )
    }

    static func nutrition(from n: [String: FlexibleDouble], servingSize: String?) -> Nutrition? {
        let hasServing = n["energy-kcal_serving"]?.value != nil
        let suffix = hasServing ? "_serving" : "_100g"
        func v(_ key: String) -> Double? { n[key + suffix]?.value }
        var nutrition = Nutrition(
            kcal: v("energy-kcal"),
            protein: v("proteins"),
            carbs: v("carbohydrates"),
            fat: v("fat"),
            sugar: v("sugars"),
            sodium: v("sodium").map { $0 * 1000 },   // OFF stores grams
            fiber: v("fiber"),
            servingSize: hasServing ? (servingSize ?? "1 serving") : "100 g"
        )
        if nutrition.isEmpty { return nil }
        if nutrition.kcal == nil, let kj = n["energy" + suffix]?.value { nutrition.kcal = kj / 4.184 }
        return nutrition
    }
}

nonisolated struct CalorieNinjasResponse: Decodable, Sendable {
    var items: [Item]

    struct Item: Decodable, Sendable {
        var name: String?
        var calories: FlexibleDouble?
        var serving_size_g: FlexibleDouble?
        var fat_total_g: FlexibleDouble?
        var protein_g: FlexibleDouble?
        var carbohydrates_total_g: FlexibleDouble?
        var sugar_g: FlexibleDouble?
        var sodium_mg: FlexibleDouble?
        var fiber_g: FlexibleDouble?

        func toNutrition() -> Nutrition? {
            let n = Nutrition(
                kcal: calories?.value, protein: protein_g?.value, carbs: carbohydrates_total_g?.value,
                fat: fat_total_g?.value, sugar: sugar_g?.value, sodium: sodium_mg?.value, fiber: fiber_g?.value,
                servingSize: serving_size_g?.value.map { "\(Int($0)) g" }
            )
            return n.isEmpty ? nil : n
        }
    }
}
