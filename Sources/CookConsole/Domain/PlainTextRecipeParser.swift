import Foundation

struct RecipeImportError: Error, Equatable, LocalizedError, Sendable {
    let line: Int
    let reason: String

    var errorDescription: String? {
        "Line \(line): \(reason)"
    }
}

enum PlainTextRecipeParser {
    static let maximumUTF8ByteCount = 1_048_576
    static let maximumLineCount = 10_000
    static let maximumIngredientCount = 1_000
    static let maximumStepCount = 1_000

    private struct SourceLine {
        let number: Int
        let text: String
    }

    static func parse(_ source: String) throws -> Recipe {
        guard source.utf8.count <= maximumUTF8ByteCount else {
            throw RecipeImportError(
                line: 1,
                reason: "Input exceeds the maximum of \(maximumUTF8ByteCount) UTF-8 bytes."
            )
        }
        let logicalLineCount = countLogicalLines(in: source)
        guard logicalLineCount <= maximumLineCount else {
            throw RecipeImportError(
                line: maximumLineCount + 1,
                reason: "Input exceeds the maximum of \(maximumLineCount) lines."
            )
        }
        let lines = nonemptyLines(in: source)
        guard let firstLine = lines.first else {
            throw RecipeImportError(line: 1, reason: "Expected Title: on the first line.")
        }

        var cursor = 0
        let title = try value(after: "Title:", at: lines, cursor: &cursor)
        guard !title.isEmpty else {
            throw RecipeImportError(line: firstLine.number, reason: "Recipe title must not be blank.")
        }

        let servingsText = try value(after: "Servings:", at: lines, cursor: &cursor)
        guard let servings = Double(servingsText), servings.isFinite, servings > 0 else {
            let line = lines[min(cursor - 1, lines.count - 1)]
            throw RecipeImportError(
                line: line.number,
                reason: "Servings must be a finite number greater than zero."
            )
        }

        var tags: [String] = []
        if cursor < lines.count, hasPrefix(lines[cursor].text, prefix: "Tags:") {
            let rawTags = String(lines[cursor].text.dropFirst("Tags:".count))
            tags = rawTags.split(separator: ",").map(String.init)
            cursor += 1
        }

        try expect("Ingredients:", at: lines, cursor: &cursor)
        var ingredients: [Ingredient] = []
        while cursor < lines.count, !equals(lines[cursor].text, "Steps:") {
            guard ingredients.count < maximumIngredientCount else {
                throw RecipeImportError(
                    line: lines[cursor].number,
                    reason: "Input exceeds the maximum of \(maximumIngredientCount) ingredients."
                )
            }
            ingredients.append(try parseIngredient(lines[cursor]))
            cursor += 1
        }
        guard !ingredients.isEmpty else {
            throw RecipeImportError(
                line: lineNumber(at: cursor, in: lines),
                reason: "Ingredients: must contain at least one ingredient line."
            )
        }

        try expect("Steps:", at: lines, cursor: &cursor)
        var steps: [RecipeStep] = []
        var expectedStepNumber = 1
        while cursor < lines.count {
            guard steps.count < maximumStepCount else {
                throw RecipeImportError(
                    line: lines[cursor].number,
                    reason: "Input exceeds the maximum of \(maximumStepCount) steps."
                )
            }
            steps.append(try parseStep(lines[cursor], expectedNumber: expectedStepNumber))
            expectedStepNumber += 1
            cursor += 1
        }
        guard !steps.isEmpty else {
            throw RecipeImportError(
                line: lines.last?.number ?? 1,
                reason: "Steps: must contain at least one numbered step."
            )
        }

        do {
            return try Recipe(
                title: title,
                servings: servings,
                ingredients: ingredients,
                steps: steps,
                tags: tags
            )
        } catch {
            throw RecipeImportError(
                line: lines.last?.number ?? 1,
                reason: "Recipe is invalid: \(error.localizedDescription)"
            )
        }
    }

    private static func parseIngredient(_ line: SourceLine) throws -> Ingredient {
        guard line.text.hasPrefix("- ") else {
            throw RecipeImportError(
                line: line.number,
                reason: "Each ingredient must use '- <amount> <unit> <name>'."
            )
        }
        let tokens = line.text.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3 else {
            throw RecipeImportError(
                line: line.number,
                reason: "Ingredient must include an amount, unit, and name."
            )
        }

        var unitIndex = 1
        let amount: Double?
        if tokens.count >= 4, tokens[1].contains("/") {
            amount = parseMixedNumber(whole: tokens[0], fraction: tokens[1])
            unitIndex = 2
        } else {
            amount = parseNumber(tokens[0])
        }
        guard let amount, amount.isFinite, amount > 0 else {
            throw RecipeImportError(
                line: line.number,
                reason: "Ingredient amount must be a positive decimal, fraction, or mixed fraction."
            )
        }
        guard unitIndex < tokens.count, let unit = IngredientUnit(importToken: tokens[unitIndex]) else {
            throw RecipeImportError(line: line.number, reason: "Ingredient unit is not supported.")
        }
        let nameIndex = unitIndex + 1
        guard nameIndex < tokens.count else {
            throw RecipeImportError(line: line.number, reason: "Ingredient name must not be blank.")
        }

        do {
            return try Ingredient(
                name: tokens[nameIndex...].joined(separator: " "),
                amount: amount,
                unit: unit
            )
        } catch {
            throw RecipeImportError(line: line.number, reason: "Ingredient is invalid: \(error.localizedDescription)")
        }
    }

    private static func parseStep(
        _ line: SourceLine,
        expectedNumber: Int
    ) throws -> RecipeStep {
        guard let separator = line.text.firstIndex(where: { $0 == "." || $0 == ")" }),
              let number = Int(line.text[..<separator]),
              number == expectedNumber
        else {
            throw RecipeImportError(
                line: line.number,
                reason: "Expected step \(expectedNumber) in sequential numbered form."
            )
        }
        let instruction = line.text[line.text.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try RecipeStep(instruction: instruction)
        } catch {
            throw RecipeImportError(line: line.number, reason: "Step is invalid: \(error.localizedDescription)")
        }
    }

    private static func parseNumber(_ token: String) -> Double? {
        if token.contains("/") {
            return parseFraction(token)
        }
        guard isUnsignedDecimal(token) else { return nil }
        return Double(token)
    }

    private static func parseFraction(_ token: String) -> Double? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = positiveInteger(parts[0]),
              let denominator = positiveInteger(parts[1])
        else { return nil }
        return Double(numerator) / Double(denominator)
    }

    private static func parseMixedNumber(whole: String, fraction: String) -> Double? {
        guard let whole = nonnegativeInteger(whole) else { return nil }
        let parts = fraction.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = positiveInteger(parts[0]),
              let denominator = positiveInteger(parts[1]),
              numerator < denominator
        else { return nil }
        return Double(whole) + (Double(numerator) / Double(denominator))
    }

    private static func positiveInteger(_ token: Substring) -> Int? {
        guard isASCIIDigits(token), let value = Int(token), value > 0 else { return nil }
        return value
    }

    private static func nonnegativeInteger(_ token: String) -> Int? {
        guard isASCIIDigits(token[...]) else { return nil }
        return Int(token)
    }

    private static func isASCIIDigits(_ token: Substring) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isUnsignedDecimal(_ token: String) -> Bool {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              pieces.contains(where: { !$0.isEmpty })
        else { return false }
        return pieces.allSatisfy { $0.isEmpty || isASCIIDigits($0) }
    }

    private static func countLogicalLines(in source: String) -> Int {
        var count = 1
        for character in source where isNewline(character) {
            count += 1
            if count > maximumLineCount { return count }
        }
        return count
    }

    private static func nonemptyLines(in source: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var lineStart = source.startIndex
        var lineNumber = 1

        for index in source.indices where isNewline(source[index]) {
            appendLine(source[lineStart..<index], number: lineNumber, to: &result)
            lineStart = source.index(after: index)
            lineNumber += 1
        }
        appendLine(source[lineStart...], number: lineNumber, to: &result)
        return result
    }

    private static func appendLine(
        _ rawLine: Substring,
        number: Int,
        to lines: inout [SourceLine]
    ) {
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(SourceLine(number: number, text: text))
        }
    }

    private static func isNewline(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }

    private static func value(
        after prefix: String,
        at lines: [SourceLine],
        cursor: inout Int
    ) throws -> String {
        guard cursor < lines.count, hasPrefix(lines[cursor].text, prefix: prefix) else {
            throw RecipeImportError(
                line: lineNumber(at: cursor, in: lines),
                reason: "Expected \(prefix)."
            )
        }
        let value = String(lines[cursor].text.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cursor += 1
        return value
    }

    private static func expect(
        _ expected: String,
        at lines: [SourceLine],
        cursor: inout Int
    ) throws {
        guard cursor < lines.count, equals(lines[cursor].text, expected) else {
            throw RecipeImportError(
                line: lineNumber(at: cursor, in: lines),
                reason: "Expected \(expected)."
            )
        }
        cursor += 1
    }

    private static func lineNumber(at cursor: Int, in lines: [SourceLine]) -> Int {
        guard !lines.isEmpty else { return 1 }
        return cursor < lines.count ? lines[cursor].number : lines[lines.count - 1].number
    }

    private static func hasPrefix(_ text: String, prefix: String) -> Bool {
        text.lowercased().hasPrefix(prefix.lowercased())
    }

    private static func equals(_ text: String, _ expected: String) -> Bool {
        text.caseInsensitiveCompare(expected) == .orderedSame
    }
}

private extension IngredientUnit {
    init?(importToken: String) {
        switch importToken.lowercased() {
        case "each", "ea": self = .each
        case "tsp", "teaspoon", "teaspoons": self = .teaspoon
        case "tbsp", "tablespoon", "tablespoons": self = .tablespoon
        case "cup", "cups": self = .cup
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres": self = .milliliter
        case "l", "liter", "liters", "litre", "litres": self = .liter
        case "g", "gram", "grams": self = .gram
        case "kg", "kilogram", "kilograms": self = .kilogram
        case "oz", "ounce", "ounces": self = .ounce
        case "lb", "lbs", "pound", "pounds": self = .pound
        default: return nil
        }
    }
}
