import Foundation

/// Finding files by name with Spotlight's index (the same one Finder uses), for
/// `f syllabus` in the launcher. The query runs in Hop; this is the part that can be
/// tested: reading the command, the name patterns, and ranking what comes back.
public enum FileSearch {
    public struct Hit: Equatable, Sendable {
        public let name: String
        public let path: String
        public let lastUsed: Date?

        public init(name: String, path: String, lastUsed: Date?) {
            self.name = name
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    /// "f syllabus", "file syllabus" or "find syllabus" -> "syllabus".
    public static func query(fromCommand text: String) -> String? {
        for prefix in ["f ", "file ", "files ", "find "] where text.lowercased().hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.count >= 2 ? rest : nil
        }
        return nil
    }

    /// One LIKE pattern per word, matching anywhere in the name ("calc syl" finds
    /// "Calc II Syllabus.pdf"). Spotlight's wildcards in the text are escaped.
    public static func namePatterns(_ query: String) -> [String] {
        query.split(separator: " ").map { word in
            var escaped = ""
            for character in word {
                if "*?\\".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return "*\(escaped)*"
        }
    }

    /// Places nobody means when looking for their own files.
    public static func isNoise(_ path: String) -> Bool {
        let noisy = ["/Library/", "/node_modules/", "/.git/", "/.build/", "/DerivedData/", "/.Trash/", "/Pods/", "/.venv/",
                     "/venv/", "/__pycache__/", "/vendor/", "/bower_components/", "/site-packages/", "/target/debug/", "/target/release/"]
        return noisy.contains { path.contains($0) } || path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Best matches first: names that start with the query, then other name matches,
    /// with recently used files ahead among equals.
    public static func rank(_ hits: [Hit], query: String, limit: Int = 12) -> [Hit] {
        let lowered = query.lowercased()
        func score(_ hit: Hit) -> Int {
            let name = hit.name.lowercased()
            var score = FuzzyMatcher.score(query, in: hit.name) ?? 0
            if name.hasPrefix(lowered) { score += 1000 } else if name.contains(lowered) { score += 500 }
            return score
        }
        return hits.filter { !isNoise($0.path) }
            .map { ($0, score($0)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (a.0.lastUsed ?? .distantPast) > (b.0.lastUsed ?? .distantPast)
            }
            .prefix(limit)
            .map(\.0)
    }
}
