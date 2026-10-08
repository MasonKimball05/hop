import Foundation

/// The inline calculator: arithmetic ("12*1.08", "(3+4)^2", "sqrt(2)") and unit
/// conversion ("5 km in miles", "72 f to c", "1.5 gb in mb").
///
/// It only answers things that look like a calculation (an operator, a
/// function or a conversion), so typing an app name never shows a result.
public enum Calculator {
    public struct Answer: Equatable, Sendable {
        /// What to show and copy, e.g. "3.10686 mi".
        public let text: String
        /// What was understood, e.g. "5 km in mi".
        public let detail: String
    }

    public static func evaluate(_ input: String) -> Answer? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let conversion = UnitConversion.convert(trimmed) { return conversion }

        guard looksLikeMath(trimmed) else { return nil }
        var parser = ExpressionParser(trimmed)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Answer(text: format(value), detail: trimmed)
    }

    static func looksLikeMath(_ s: String) -> Bool {
        // A leading "-" alone ("-5") isn't a calculation; one between operands is.
        let body = s.drop(while: { $0 == "-" || $0 == " " })
        if body.contains(where: { "+-*/^%×÷()".contains($0) }) { return true }
        let lower = s.lowercased()
        return ExpressionParser.functions.keys.contains { lower.hasPrefix($0 + "(") }
            || lower == "pi" || lower == "e"
    }

    /// Up to 10 significant digits, no trailing zeros, no scientific notation for
    /// everyday numbers.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = abs(value) >= 1e15 || abs(value) < 1e-6 ? .scientific : .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumSignificantDigits = 10
        formatter.usesSignificantDigits = true
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: value as NSNumber) ?? String(value)
    }
}

/// Recursive-descent parser for
///   expr   := term (("+" | "-") term)*
///   term   := unary (("*" | "/" | "%") unary)*
///   unary  := "-" unary | power           (-3^2 = -(3^2) = -9, as in math)
///   power  := atom ("^" unary)?           (right-associative: 2^3^2 = 2^9; 2^-1 works)
///   atom   := number | constant | function "(" expr ")" | "(" expr ")"
struct ExpressionParser {
    static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "abs": { abs($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "log": { log10($0) }, "ln": { log($0) },
        "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
    ]
    static let constants: [String: Double] = ["pi": .pi, "e": M_E]

    private let chars: [Character]
    private var i = 0

    init(_ text: String) {
        chars = Array(text.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/"))
    }

    /// nil on anything malformed, including leftovers ("2 3").
    mutating func parse() -> Double? {
        guard let value = expression() else { return nil }
        skipSpaces()
        return i == chars.count ? value : nil
    }

    private mutating func expression() -> Double? {
        guard var value = term() else { return nil }
        while true {
            if take("+") { guard let rhs = term() else { return nil }; value += rhs }
            else if take("-") { guard let rhs = term() else { return nil }; value -= rhs }
            else { return value }
        }
    }

    private mutating func term() -> Double? {
        guard var value = unary() else { return nil }
        while true {
            if take("*") { guard let rhs = unary() else { return nil }; value *= rhs }
            else if take("/") { guard let rhs = unary() else { return nil }; value /= rhs }
            else if take("%") { guard let rhs = unary() else { return nil }; value = value.truncatingRemainder(dividingBy: rhs) }
            else { return value }
        }
    }

    private mutating func unary() -> Double? {
        if take("-") { return unary().map { -$0 } }
        if take("+") { return unary() }
        return power()
    }

    private mutating func power() -> Double? {
        guard let base = atom() else { return nil }
        if take("^") {
            guard let exponent = unary() else { return nil }
            return pow(base, exponent)
        }
        return base
    }

    private mutating func atom() -> Double? {
        skipSpaces()
        if take("(") {
            guard let value = expression(), take(")") else { return nil }
            return value
        }
        if i < chars.count, chars[i].isLetter {
            let start = i
            while i < chars.count, chars[i].isLetter { i += 1 }
            let name = String(chars[start..<i])
            if let f = Self.functions[name] {
                guard take("("), let arg = expression(), take(")") else { return nil }
                return f(arg)
            }
            return Self.constants[name]
        }
        return number()
    }

    private mutating func number() -> Double? {
        skipSpaces()
        let start = i
        while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," { i += 1 }
        guard i > start else { return nil }
        // "1,000" is a thousands separator here, not a list.
        return Double(String(chars[start..<i]).replacingOccurrences(of: ",", with: ""))
    }

    private mutating func take(_ c: Character) -> Bool {
        skipSpaces()
        guard i < chars.count, chars[i] == c else { return false }
        i += 1
        return true
    }

    private mutating func skipSpaces() {
        while i < chars.count, chars[i] == " " { i += 1 }
    }
}
