import Foundation
import CoreGraphics
import Vision
import FoundationModels

/// Vision OCR (accurate, no language correction) grouped into visual lines.
final class VisionReceiptTextRecognizer: ReceiptTextRecognizer {
    func recognizeLines(in image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image)
        let fragments = observations.compactMap { obs -> OCRLineGrouper.Fragment? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return OCRLineGrouper.Fragment(text: text, rect: obs.boundingBox.cgRect)
        }
        return OCRLineGrouper.lines(from: fragments)
    }
}

/// Expands receipt abbreviations. Uses the on-device Foundation Model when Apple Intelligence is
/// available, otherwise a small abbreviation dictionary.
final class SmartReceiptNormalizer: ReceiptNormalizer {
    private let shelfLife: ShelfLifeService
    private let dictionary = AbbreviationNormalizer()

    init(shelfLife: ShelfLifeService = .shared) {
        self.shelfLife = shelfLife
    }

    var usesOnDeviceModel: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func normalize(_ lines: [ParsedReceiptLine]) async -> [NormalizedReceiptLine] {
        let fallback = lines.map { dictionary.normalize($0, shelfLife: shelfLife) }
        guard usesOnDeviceModel, !lines.isEmpty else { return fallback }
        do {
            let guesses = try await modelGuesses(for: lines)
            return lines.indices.map { idx in
                guard let guess = guesses.first(where: { $0.index == idx }),
                      !guess.name.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback[idx] }
                let name = guess.name.trimmingCharacters(in: .whitespaces).capitalizedFirst
                var category = guess.category.lowercased().replacingOccurrences(of: " ", with: "_")
                if shelfLife.category(id: category) == nil {
                    category = shelfLife.categoryID(forName: name)
                }
                if category == ShelfLifeService.unknownCategoryID { category = fallback[idx].categoryID }
                return NormalizedReceiptLine(line: lines[idx], name: name, categoryID: category)
            }
        } catch {
            return fallback
        }
    }

    private func modelGuesses(for lines: [ParsedReceiptLine]) async throws -> [ReceiptItemGuess] {
        let categoryIDs = shelfLife.categories.map(\.id).joined(separator: ", ")
        let session = LanguageModelSession(instructions: """
            You expand abbreviated US grocery receipt lines into plain product names.
            Drop store brand prefixes (GV, KRO, KS, GG, HEB, PRVT SEL), sizes, and codes.
            Keep meaningful qualifiers like "2%", "greek", "boneless".
            Example: "GV 2% MLK GAL" -> name "2% milk", category "milk".
            Example: "CHKN BRST BNLS" -> name "boneless chicken breast", category "chicken".
            Choose category from: \(categoryIDs). Use "other" if none fit.
            """)
        let prompt = lines.enumerated().map { "\($0.offset): \($0.element.name)" }.joined(separator: "\n")
        let response = try await session.respond(
            to: "Expand each receipt line. Return one item per line index.\n\(prompt)",
            generating: ReceiptGuesses.self
        )
        return response.content.items
    }
}

@Generable
nonisolated struct ReceiptItemGuess {
    @Guide(description: "The index number of the input line")
    var index: Int
    @Guide(description: "Plain-English generic product name in lowercase, e.g. '2% milk' or 'baby spinach'")
    var name: String
    @Guide(description: "One category id from the allowed list")
    var category: String
}

@Generable
nonisolated struct ReceiptGuesses {
    var items: [ReceiptItemGuess]
}

/// Dictionary-based expansion of common US receipt abbreviations.
nonisolated struct AbbreviationNormalizer: Sendable {
    static let drop: Set<String> = ["gv", "kro", "ks", "gg", "heb", "prvt", "sel", "mkt", "pantry", "kirkland",
                                    "gal", "hg", "qt", "pt", "oz", "lb", "lbs", "ct", "pk", "ea", "fl", "dz",
                                    "good&gather", "1lb", "8oz", "5oz", "18ct", "12ct"]
    static let expansions: [String: String] = [
        "mlk": "milk", "whl": "whole", "hlf": "half", "org": "organic", "bnls": "boneless", "sknls": "skinless",
        "chkn": "chicken", "chk": "chicken", "brst": "breast", "grnd": "ground", "bf": "beef", "ygrt": "yogurt",
        "yog": "yogurt", "grk": "greek", "strawb": "strawberries", "strwb": "strawberries", "bnna": "bananas",
        "ban": "bananas", "spnch": "spinach", "lttc": "lettuce", "tom": "tomatoes", "pot": "potatoes",
        "brd": "bread", "wht": "wheat", "chs": "cheese", "ched": "cheddar", "shrd": "shredded",
        "mozz": "mozzarella", "lg": "large", "oj": "orange juice", "jce": "juice", "crm": "cream",
        "btr": "butter", "pnt": "peanut", "apl": "apples", "avo": "avocado", "brcli": "broccoli",
        "broc": "broccoli", "crt": "carrots", "carr": "carrots", "onn": "onions", "grn": "green",
        "pep": "peppers", "cuc": "cucumber", "mush": "mushrooms", "bcn": "bacon", "saus": "sausage",
        "trky": "turkey", "salm": "salmon", "shrmp": "shrimp", "tort": "tortillas", "humm": "hummus",
        "sr": "sour", "bluebry": "blueberries", "rasp": "raspberries", "veg": "vegetables", "frz": "frozen",
        "sdwch": "sandwich", "pkd": "packed", "rst": "roast", "wtr": "water", "sod": "soda", "grape": "grapes",
    ]

    func expand(_ raw: String) -> String {
        let words = raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        let expanded = words.compactMap { word -> String? in
            if Self.drop.contains(word) { return nil }
            if word.range(of: #"^\d+(oz|lb|ct|pk|gal)$"#, options: .regularExpression) != nil { return nil }
            return Self.expansions[word] ?? word
        }
        let result = expanded.joined(separator: " ")
        return result.isEmpty ? raw.lowercased() : result
    }

    func normalize(_ line: ParsedReceiptLine, shelfLife: ShelfLifeService) -> NormalizedReceiptLine {
        let name = expand(line.name)
        var category = shelfLife.categoryID(forName: name)
        if category == ShelfLifeService.unknownCategoryID { category = shelfLife.categoryID(forName: line.name) }
        return NormalizedReceiptLine(line: line, name: name.capitalizedFirst, categoryID: category)
    }
}

extension String {
    nonisolated var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
