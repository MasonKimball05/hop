import Foundation

/// Scores how well a typed query matches a name, Raycast/Spotlight style:
/// "vsc" finds "Visual Studio Code", "term" finds "Terminal".
///
/// Every query character has to appear in the name, in order. Matches score
/// higher when they start the name or a word, run consecutively, or spell
/// the name's initials; shorter names win ties.
public enum FuzzyMatcher {
    /// Returns nil when the query doesn't match at all.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let original = Array(candidate)
        let lower = Array(candidate.lowercased())
        guard original.count == lower.count else {
            // Lowercasing changed the length (rare: "İ"); fall back to a plain search.
            return candidate.lowercased().contains(String(q)) ? 1 : nil
        }

        var score = 0
        var qi = 0
        var previous = -2
        for i in lower.indices where qi < q.count {
            guard lower[i] == q[qi] else { continue }
            var points = 1
            if i == previous + 1 { points += 5 }
            if i == 0 {
                points += 10
            } else if isWordStart(original, i) {
                points += 8
            }
            score += points
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }

        let lowerName = candidate.lowercased()
        let compactQuery = String(q)
        if lowerName.hasPrefix(compactQuery) { score += 25 }
        if initials(of: original).hasPrefix(compactQuery) { score += 30 }
        score -= original.count / 4
        return score
    }

    static func isWordStart(_ s: [Character], _ i: Int) -> Bool {
        let previous = s[i - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." { return true }
        return previous.isLowercase && s[i].isUppercase // camelCase: "FaceTime" -> T
    }

    /// "Visual Studio Code" -> "vsc", "FaceTime" -> "ft".
    static func initials(of s: [Character]) -> String {
        var out = ""
        for i in s.indices where s[i].isLetter || s[i].isNumber {
            if i == 0 || isWordStart(s, i) { out.append(Character(s[i].lowercased())) }
        }
        return out
    }
}
