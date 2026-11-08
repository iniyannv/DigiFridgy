import Testing
import Foundation
import CoreGraphics
@testable import DigiFridgy

struct ReceiptParserTests {
    let parser = ReceiptParser()

    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines) }

    @Test func walmartReceiptKeepsItemsAndDropsTotals() {
        let items = parser.parse(lines(SampleReceipts.walmart))
        let names = items.map(\.name)
        #expect(items.count == 7)
        #expect(names.contains("GV 2% MLK GAL"))
        #expect(names.contains("BNNA"))
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("total") })
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("visa") })
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("tax") })
        // "2 @ 1.24" applies to the eggs line that follows (2 × 1.24 = 2.48).
        #expect(items.first { $0.name.contains("EGGS") }?.quantity == 2)
        #expect(items.first { $0.name == "GV 2% MLK GAL" }?.price == 3.48)
    }

    @Test func krogerReceiptMergesRepeatedLinesAndSkipsSavings() {
        let items = parser.parse(lines(SampleReceipts.kroger))
        let yogurt = items.filter { $0.name.contains("YGRT") }
        #expect(yogurt.count == 1)
        #expect(yogurt.first?.quantity == 3)   // 1 + "2 @ 1.25" line
        #expect(!items.contains { $0.name.localizedCaseInsensitiveContains("savings") })
        #expect(!items.contains { $0.name.localizedCaseInsensitiveContains("balance") })
        #expect(items.count == 5)
    }

    @Test func targetReceiptHandlesDollarSigns() {
        let items = parser.parse(lines(SampleReceipts.target))
        #expect(items.map(\.name) == ["GOOD&GATHER HUMMUS", "GG SPRING MIX 5OZ", "ORG BLUEBERRIES", "TILLAMOOK BUTTER"])
        #expect(items.allSatisfy { $0.quantity == 1 })
    }

    @Test func quantityPrefixOnItemLine() {
        let items = parser.parse(["3 @ AVOCADOS 3.00"])
        #expect(items.first?.quantity == 3)
        #expect(items.first?.name == "AVOCADOS")
    }

    @Test func dictionaryNormalizerExpandsAbbreviations() {
        let line = ParsedReceiptLine(raw: "GV 2% MLK GAL 3.48", name: "GV 2% MLK GAL", quantity: 1, price: 3.48)
        let normalized = AbbreviationNormalizer().normalize(line, shelfLife: .shared)
        #expect(normalized.name == "2% milk")
        #expect(normalized.categoryID == "milk")
    }

    @Test func ocrFragmentsGroupIntoLines() {
        let fragments = [
            OCRLineGrouper.Fragment(text: "3.48", rect: CGRect(x: 0.8, y: 0.80, width: 0.1, height: 0.02)),
            OCRLineGrouper.Fragment(text: "MILK", rect: CGRect(x: 0.1, y: 0.801, width: 0.2, height: 0.02)),
            OCRLineGrouper.Fragment(text: "EGGS", rect: CGRect(x: 0.1, y: 0.75, width: 0.2, height: 0.02)),
            OCRLineGrouper.Fragment(text: "2.48", rect: CGRect(x: 0.8, y: 0.749, width: 0.1, height: 0.02)),
        ]
        #expect(OCRLineGrouper.lines(from: fragments) == ["MILK 3.48", "EGGS 2.48"])
    }
}
