import Foundation

/// Turns what the user typed into a safe FTS5 query.
///
/// Words are ANDed; `"two words"` is a phrase, `word*` a prefix, `OR` an alternative and `-word` (or
/// `NOT word`) an exclusion. Every term is quoted, so punctuation the user types is never FTS5 syntax.
enum QueryParser {
    struct Term: Hashable, Sendable {
        let text: String
        let isPrefix: Bool
    }

    private struct Parsed {
        var positive: [String] = []
        var negative: [String] = []
        var terms: [Term] = []
        var hasAlternatives = false
    }

    private static let token = try! NSRegularExpression(pattern: #""([^"]*)"?|(\S+)"#)

    static func ftsQuery(_ raw: String) -> String {
        let parsed = parse(raw)
        guard !parsed.positive.isEmpty else { return "" }
        var query = parsed.positive.joined(separator: " ")
        if parsed.hasAlternatives && !parsed.negative.isEmpty { query = "(\(query))" }
        return ([query] + parsed.negative.map { "NOT \($0)" }).joined(separator: " ")
    }

    /// The words and phrases to highlight in a page (exclusions left out).
    static func highlightTerms(_ raw: String) -> [Term] { parse(raw).terms }

    private static func parse(_ raw: String) -> Parsed {
        var parsed = Parsed()
        var pendingOr = false
        var nextNegative = false
        let range = NSRange(raw.startIndex..., in: raw)
        for match in token.matches(in: raw, range: range) {
            let term: Term
            var negative = nextNegative
            if let phrase = Range(match.range(at: 1), in: raw) {
                let text = raw[phrase].trimmingCharacters(in: .whitespaces)
                guard hasWordCharacter(text) else { continue }
                term = Term(text: text, isPrefix: false)
            } else if let wordRange = Range(match.range(at: 2), in: raw) {
                var word = String(raw[wordRange])
                switch word {
                case "OR": pendingOr = true; continue
                case "AND": continue
                case "NOT": nextNegative = true; continue
                default: break
                }
                if word.hasPrefix("-") {
                    negative = true
                    word = String(word.drop { $0 == "-" })
                }
                let isPrefix = word.hasSuffix("*")
                let text = word.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
                guard hasWordCharacter(text) else { continue }
                term = Term(text: text, isPrefix: isPrefix)
            } else {
                continue
            }
            let fts = "\"\(fold(term.text))\"" + (term.isPrefix ? "*" : "")
            nextNegative = false
            if negative {
                parsed.negative.append(fts)
                continue
            }
            if pendingOr && !parsed.positive.isEmpty {
                parsed.positive.append("OR")
                parsed.hasAlternatives = true
            }
            pendingOr = false
            parsed.positive.append(fts)
            parsed.terms.append(term)
        }
        return parsed
    }

    /// Accents removed the way the engine removes them before indexing (Engine/textfold.py):
    /// canonical decomposition, then every combining mark dropped.
    static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.canonicalCombiningClass == .notReordered {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func hasWordCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
