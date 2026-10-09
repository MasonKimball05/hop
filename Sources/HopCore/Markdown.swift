import Foundation

/// Splits Claude's Markdown into blocks for the Ask window to lay out: SwiftUI's own
/// Markdown support only covers inline styles (bold, code, links), so headings, lists,
/// code blocks and math are done here. Works on a half-streamed answer too: an
/// unclosed code block or math block runs to the end.
public enum Markdown {
    public struct ListItem: Equatable, Sendable {
        /// "•", or the number as written ("1.", "2)").
        public let marker: String
        /// 0 for top level, 1 for a nested item, and so on.
        public let depth: Int
        public let text: String
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case code(language: String?, text: String)
        case quote(String)
        /// Display math, already turned into Unicode.
        case math(String)
        case rule
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var quote: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            // ```lang … ```
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // the closing fence
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }

            // $$ … $$ or \[ … \], on one line or several.
            if let (open, close) = [("$$", "$$"), ("\\[", "\\]")].first(where: { trimmed.hasPrefix($0.0) }) {
                flush()
                var body = String(trimmed.dropFirst(open.count))
                if body.hasSuffix(close), body.count >= close.count {
                    body = String(body.dropLast(close.count))
                } else {
                    var more: [String] = [body]
                    while index < lines.count {
                        let next = lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                        if next.hasSuffix(close) { more.append(String(next.dropLast(close.count))); break }
                        more.append(next)
                    }
                    body = more.joined(separator: " ")
                }
                blocks.append(.math(unicodeMath(body.trimmingCharacters(in: .whitespaces))))
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
                continue
            }
            if trimmed.wholeMatch(of: #/(-\s*){3,}|(\*\s*){3,}|(_\s*){3,}/#) != nil {
                flush()
                blocks.append(.rule)
                continue
            }
            if let item = line.firstMatch(of: #/^(\s*)([-*+•]|\d+[.)])\s+(.*)$/#) {
                if !paragraph.isEmpty || !quote.isEmpty {
                    let keep = items
                    items = []
                    flush()
                    items = keep
                }
                let marker = String(item.2)
                items.append(ListItem(marker: marker.first?.isNumber == true ? marker : "\u{2022}",
                                      depth: item.1.count / 2, text: String(item.3)))
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !items.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A line under a list item, indented: more of that item.
            if !items.isEmpty, line.hasPrefix("  "), let last = items.popLast() {
                items.append(ListItem(marker: last.marker, depth: last.depth, text: last.text + "\n" + trimmed))
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    // MARK: Plain text

    /// The answer as plain text, for pasting into another app: no **, #, ` or $,
    /// lists kept as "1." and "•" lines, math as Unicode.
    public static func plainText(_ text: String) -> String {
        blocks(text).compactMap { block -> String? in
            switch block {
            case .heading(_, let text), .paragraph(let text): return inlinePlain(text)
            case .quote(let text): return inlinePlain(text)
            case .list(let items):
                return items.map { String(repeating: "  ", count: $0.depth) + $0.marker + " " + inlinePlain($0.text) }
                    .joined(separator: "\n")
            case .code(_, let code): return code
            case .math(let math): return math
            case .rule: return nil
            }
        }
        .joined(separator: "\n\n")
    }

    /// Inline Markdown (bold, italics, code, links) down to its text.
    private static func inlinePlain(_ text: String) -> String {
        let prepared = inlineMath(text)
        guard let styled = try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return prepared }
        return String(styled.characters)
    }

    // MARK: Math

    /// Turns inline math (`$…$` or `\(…\)`) into Unicode, leaving the rest alone.
    /// A `$` needs text right against it on the inside, so "$5 and $10" stays money.
    public static func inlineMath(_ text: String) -> String {
        var out = text.replacing(#/\\\((.+?)\\\)/#) { unicodeMath(String($0.1)) }
        out = out.replacing(#/\$(?!\s)([^$\n]*?[^\s$])\$/#) { unicodeMath(String($0.1)) }
        return out
    }

    /// LaTeX to readable Unicode: x^{2} → x², \frac{a}{b} → a⁄b, \sqrt{x} → √x,
    /// \alpha → α. Covers what shows up in homework help, not all of LaTeX.
    public static func unicodeMath(_ latex: String) -> String {
        var s = latex
        // Wrappers whose content is kept as is.
        s = s.replacing(#/\\(?:text|mathrm|mathbf|mathit|operatorname)\{([^{}]*)\}/#) { String($0.1) }
        s = s.replacing(#/\\left|\\right|\\displaystyle/#) { _ in "" }
        s = s.replacing(#/\^\{?\\circ\}?/#) { _ in "°" }
        s = s.replacing(#/\^\{?\\prime\}?|\\prime/#) { _ in "′" }
        // Scripts before fractions, so \frac{x^3}{3} reads x³⁄3 rather than (x^3)⁄3.
        s = s.replacing(#/\^\{([^{}]*)\}|\^([^\s\\{])/#) { match in script(String(match.1 ?? match.2 ?? ""), superscripts, "^") }
        s = s.replacing(#/_\{([^{}]*)\}|_([A-Za-z0-9])/#) { match in script(String(match.1 ?? match.2 ?? ""), subscripts, "_") }
        // Fractions and roots, innermost first so nesting works.
        for _ in 0..<4 {
            s = s.replacing(#/\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}/#) { match in
                "\(group(String(match.1)))\u{2044}\(group(String(match.2)))"
            }
            s = s.replacing(#/\\sqrt\{([^{}]*)\}/#) { "\u{221A}" + group(String($0.1)) }
        }
        s = s.replacing(#/\\([A-Za-z]+)/#) { match in symbols[String(match.1)] ?? String(match.1) }
        s = s.replacing(#/\\[,;:! ]/#) { _ in " " }
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.replacing(#/ {2,}/#) { _ in " " }.trimmingCharacters(in: .whitespaces)
    }

    /// Parentheses around anything longer than one simple term.
    private static func group(_ text: String) -> String {
        text.count <= 1 || text.allSatisfy({ $0.isLetter || $0.isNumber }) ? text : "(\(text))"
    }

    /// Super- or subscript characters when every character has one, else ^(…) or _(…).
    private static func script(_ text: String, _ table: [Character: Character], _ fallback: String) -> String {
        let converted = text.compactMap { table[$0] }
        if converted.count == text.count { return String(converted) }
        return fallback + group(text)
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ",
        "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "n": "ₙ", "o": "ₒ", "x": "ₓ", "t": "ₜ",
    ]

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ",
        "phi": "φ", "varphi": "φ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω", "Pi": "Π",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥",
        "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "infty": "∞", "int": "∫", "iint": "∬",
        "oint": "∮", "sum": "∑", "prod": "∏", "partial": "∂", "nabla": "∇", "to": "→", "rightarrow": "→",
        "leftarrow": "←", "Rightarrow": "⇒", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "in": "∈",
        "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀",
        "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "ldots": "…", "cdots": "⋯", "dots": "…",
        "degree": "°", "circ": "°", "angle": "∠", "perp": "⊥", "parallel": "∥", "propto": "∝", "sqrt": "√",
        "quad": " ", "qquad": "  ",
        // Function names stay words.
        "sin": "sin", "cos": "cos", "tan": "tan", "sec": "sec", "csc": "csc", "cot": "cot", "ln": "ln",
        "log": "log", "exp": "exp", "lim": "lim", "max": "max", "min": "min",
    ]
}
