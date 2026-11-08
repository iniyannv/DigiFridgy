import Foundation
import CoreGraphics

nonisolated struct ParsedReceiptLine: Hashable, Sendable {
    var raw: String
    /// Name text as printed (abbreviations intact), e.g. "GV 2% MLK GAL".
    var name: String
    var quantity: Int
    var price: Double?
}

nonisolated struct NormalizedReceiptLine: Hashable, Sendable {
    var line: ParsedReceiptLine
    var name: String
    var categoryID: String
}

/// Turns OCR'd receipt lines into purchasable line items.
/// Keeps `NAME ... PRICE` lines, drops totals / tax / payment / header lines, applies `2 @ 1.99` quantities.
nonisolated struct ReceiptParser: Sendable {
    static let dropWords: [String] = [
        "subtotal", "sub total", "total", "tax", "balance", "change", "cash", "visa", "mastercard", "amex",
        "discover", "debit", "credit", "card", "tend", "tender", "payment", "approved", "auth", "ref",
        "thank", "thanks", "receipt", "savings", "you saved", "member", "rewards", "coupon", "discount",
        "items sold", "item count", "st#", "tr#", "op#", "te#", "tc#", "terminal", "cashier", "manager",
        "store", "survey", "www", ".com", "points", "fuel", "account", "chip", "aid", "invoice", "due",
        "price you pay", "bottle deposit", "bag fee", "bag charge", "eft", "us debit",
    ]

    private static var itemPattern: Regex<(Substring, name: Substring, price: Substring)> { /^(?<name>.*?[A-Za-z].*?)\s+\$?(?<price>-?\d{1,4}[.,]\d{2})(?:\s*-)?(?:\s+[A-Z]{1,2})?\s*$/ }
    private static var qtyOnlyPattern: Regex<(Substring, qty: Substring, unit: Substring)> { /^(?<qty>\d{1,2})\s*(?:@|AT|X|x)\s*(?:\d+\s*(?:FOR|\/)\s*)?\$?(?<unit>\d{1,4}[.,]\d{2})/ }
    private static var qtyPrefixPattern: Regex<(Substring, qty: Substring, rest: Substring)> { /^(?<qty>\d{1,2})\s*(?:@|X|x)\s+(?<rest>.+)$/ }

    func parse(_ lines: [String]) -> [ParsedReceiptLine] {
        var items: [ParsedReceiptLine] = []
        var pendingQty: Int?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 3 else { continue }
            if isDropLine(line) { continue }

            // Standalone quantity line: "2 @ 1.99" / "2 AT 1 FOR 1.99"
            if let m = line.firstMatch(of: Self.qtyOnlyPattern), !hasNameText(afterQuantityIn: line) {
                let qty = Int(m.output.qty) ?? 1
                let unit = Self.price(String(m.output.unit))
                if var last = items.last, last.quantity == 1, let lastPrice = last.price, let unit,
                   abs(lastPrice - unit * Double(qty)) < 0.05 {
                    last.quantity = qty
                    items[items.count - 1] = last
                } else {
                    pendingQty = qty
                }
                continue
            }

            // Negative amounts ("0.50-") are coupons / savings.
            if line.range(of: #"\d[.,]\d{2}\s*-"#, options: .regularExpression) != nil { continue }
            guard let m = line.firstMatch(of: Self.itemPattern) else { continue }
            guard let price = Self.price(String(m.output.price)), price > 0 else { continue }  // skip coupons
            var name = String(m.output.name)
            var qty = pendingQty ?? 1
            pendingQty = nil

            if let q = name.firstMatch(of: Self.qtyPrefixPattern) {
                qty = Int(q.output.qty) ?? qty
                name = String(q.output.rest)
            }
            name = clean(name)
            guard name.filter(\.isLetter).count >= 2 else { continue }
            items.append(ParsedReceiptLine(raw: line, name: name, quantity: max(qty, 1), price: price))
        }
        return merged(items)
    }

    /// Same product printed on several lines → one line with summed quantity.
    private func merged(_ items: [ParsedReceiptLine]) -> [ParsedReceiptLine] {
        var result: [ParsedReceiptLine] = []
        for item in items {
            if let idx = result.firstIndex(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) {
                result[idx].quantity += item.quantity
                result[idx].price = (result[idx].price ?? 0) + (item.price ?? 0)
            } else {
                result.append(item)
            }
        }
        return result
    }

    func isDropLine(_ line: String) -> Bool {
        let lower = " " + line.lowercased() + " "
        for word in Self.dropWords {
            if word.contains(where: { !$0.isLetter && $0 != " " }) {
                if lower.contains(word) { return true }
            } else if lower.range(of: "(^|[^a-z])\(word)([^a-z]|$)", options: .regularExpression) != nil {
                return true
            }
        }
        // Phone numbers, dates, times
        if line.range(of: #"\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"\d{1,2}/\d{1,2}/\d{2,4}"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true }
        return false
    }

    private func hasNameText(afterQuantityIn line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: #"(?i)\b(at|for|x|lb|ea)\b"#, with: "", options: .regularExpression)
        return stripped.filter(\.isLetter).count >= 3
    }

    /// Strips UPC codes, weights ("2.31 lb @ 0.59/lb") and stray symbols.
    func clean(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: #"\d+(\.\d+)?\s*(lb|lbs|kg)\s*@.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\b\d{6,}\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*#$]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        // Trailing tax/food-stamp flag letter left over after removing the UPC ("... MLK GAL F").
        s = s.replacingOccurrences(of: #"\s+[A-Z]$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    static func price(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}

/// Groups OCR text fragments into visual lines (receipts put name and price in separate fragments).
nonisolated enum OCRLineGrouper {
    struct Fragment: Sendable {
        var text: String
        /// Normalized rect, origin bottom-left (Vision convention).
        var rect: CGRect
    }

    static func lines(from fragments: [Fragment]) -> [String] {
        guard !fragments.isEmpty else { return [] }
        let heights = fragments.map(\.rect.height).sorted()
        let tolerance = max(heights[heights.count / 2] * 0.55, 0.004)
        var rows: [(midY: Double, parts: [Fragment])] = []
        for fragment in fragments.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let idx = rows.firstIndex(where: { abs($0.midY - fragment.rect.midY) <= tolerance }) {
                rows[idx].parts.append(fragment)
            } else {
                rows.append((fragment.rect.midY, [fragment]))
            }
        }
        return rows
            .sorted { $0.midY > $1.midY }
            .map { $0.parts.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
    }
}

/// Sample receipts for the simulator and unit tests.
nonisolated enum SampleReceipts {
    static let walmart = """
    Walmart Supercenter
    Save money. Live better.
    (972) 555-0142
    ST# 0512 OP# 009041 TE# 41 TR# 07740
    GV 2% MLK GAL 007874235186 F 3.48 N
    BNNA 000000004011 F 1.36 N
    BABY SPINACH 068113100123 F 2.98 N
    2 @ 1.24
    GV LG EGGS 18CT 007874212708 F 2.48 N
    STRAWB 1LB 003338320027 F 2.97 N
    CHKN BRST BNLS 022655700000 F 8.72 N
    SHRD CHED 8OZ 007874202301 F 2.24 N
    SUBTOTAL 24.23
    TAX 1 8.250 % 0.00
    TOTAL 24.23
    VISA TEND 24.23
    CHANGE DUE 0.00
    # ITEMS SOLD 8
    11/06/26 18:42:10
    """

    static let kroger = """
    KROGER
    1234 Coit Rd Richardson TX
    KRO WHOLE MILK HG 2.79
    CHOBANI GRK YGRT 1.25
    2 @ 1.25
    CHOBANI GRK YGRT 2.50
    ROMAINE HEARTS 3.49
    AVOCADO HASS 1.00
    KRO CREAM CHS 1.89
    SC KROGER SAVINGS 0.50-
    BALANCE 12.92
    KROGER PLUS CUSTOMER
    """

    static let target = """
    TARGET
    Dallas North
    GROCERY
    GOOD&GATHER HUMMUS $3.99
    GG SPRING MIX 5OZ $3.49
    ORG BLUEBERRIES $4.99
    TILLAMOOK BUTTER $5.29
    SUBTOTAL $17.76
    T = TX TAX 8.25000 on $0.00 $0.00
    TOTAL $17.76
    *1234 DEBIT TOTAL PAYMENT $17.76
    """

    static let all: [(name: String, text: String)] = [("Walmart", walmart), ("Kroger", kroger), ("Target", target)]
}
