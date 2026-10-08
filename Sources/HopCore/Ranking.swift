import Foundation

/// Remembers how often each result is chosen, so the apps you actually use
/// rise to the top: after a few launches, "s" means Safari, not Shortcuts.
public struct UsageCounts: Sendable {
    public private(set) var counts: [String: Int]

    public init(_ counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public mutating func record(_ key: String) {
        counts[key, default: 0] += 1
    }

    /// Grows with use but levels off (log scale), so a favorite is boosted
    /// without burying a much better text match.
    public func boost(_ key: String) -> Int {
        guard let n = counts[key], n > 0 else { return 0 }
        return Int((log2(Double(n) + 1) * 6).rounded())
    }
}

/// Fuzzy-matches named items against a query and orders them best first.
public enum Ranking {
    public static func rank<T>(_ items: [T], query: String, name: (T) -> String, key: (T) -> String,
                               usage: UsageCounts, limit: Int = 50) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // No query: most used first, then alphabetical.
            return Array(items.sorted {
                let (a, b) = (usage.boost(key($0)), usage.boost(key($1)))
                return a != b ? a > b : name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }.prefix(limit))
        }
        let scored: [(item: T, score: Int)] = items.compactMap { item in
            guard let s = FuzzyMatcher.score(trimmed, in: name(item)) else { return nil }
            return (item, s + usage.boost(key(item)))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : name($0.item) < name($1.item) }
            .prefix(limit)
            .map(\.item)
    }
}
