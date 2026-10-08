import Foundation

/// Saved text to paste: an address, a canned reply, a command I always forget.
/// Stored in ~/Library/Application Support/Hop/snippets.json.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    /// Fills in placeholders: {date} (Oct 2, 2026), {time} (5:42 PM),
    /// {isodate} (2026-10-02) and {clipboard} (whatever is copied now).
    public func expanded(now: Date = .now, clipboard: String? = nil, timeZone: TimeZone = .current) -> String {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: now)
        }
        var out = text
        if out.contains("{date}") { out = out.replacingOccurrences(of: "{date}", with: format("MMM d, yyyy")) }
        if out.contains("{time}") { out = out.replacingOccurrences(of: "{time}", with: format("h:mm a")) }
        if out.contains("{isodate}") { out = out.replacingOccurrences(of: "{isodate}", with: format("yyyy-MM-dd")) }
        if out.contains("{clipboard}") { out = out.replacingOccurrences(of: "{clipboard}", with: clipboard ?? "") }
        return out
    }
}

public enum Snippets {
    public static let fileName = "snippets.json"

    /// Starters that show how placeholders work. They're mine to edit or delete.
    public static let defaults: [Snippet] = [
        Snippet(name: "Shrug", text: "\u{00AF}\\_(\u{30C4})_/\u{00AF}"),
        Snippet(name: "Today's Date", text: "{date}"),
        Snippet(name: "Git Commit Message from Clipboard", text: "git commit -m \"{clipboard}\""),
    ]

    /// Snippets whose name or text contain every word of the query, by name.
    public static func search(_ query: String, in snippets: [Snippet]) -> [Snippet] {
        let words = query.lowercased().split(separator: " ")
        let sorted = snippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !words.isEmpty else { return sorted }
        return sorted.filter { snippet in
            let hay = (snippet.name + " " + snippet.text).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
