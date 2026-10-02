import Foundation

/// Locale-aware lossless decimal editing shared by the recipe editor and the
/// grocery-list serving steppers (issue #20). The recipe editor kept editable
/// numbers lossless (issue #3 review) — the same rule applies wherever the
/// user types an amount, so the helper lives in the Linux-testable domain.
enum DecimalParsing {
    static func string(_ value: Double, locale: Locale = .current) -> String {
        let lossless = String(value)
        guard let separator = locale.decimalSeparator, separator != "." else {
            return lossless
        }
        return lossless.replacingOccurrences(of: ".", with: separator)
    }

    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        if separator != ".", trimmed.contains(".") { return nil }
        return Double(trimmed.replacingOccurrences(of: separator, with: "."))
    }
}
