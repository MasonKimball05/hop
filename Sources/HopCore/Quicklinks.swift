import Foundation

/// A saved link. With "{query}" in the URL it's a search: typing its keyword
/// then a query ("g swift actors") fills it in. Without, it's a bookmark that
/// shows up in search by name.
public struct Quicklink: Codable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var keyword: String?

    public init(name: String, url: String, keyword: String? = nil) {
        self.name = name
        self.url = url
        self.keyword = keyword
    }

    public var takesQuery: Bool { url.contains("{query}") }

    public func url(for query: String = "") -> URL? {
        guard takesQuery else { return URL(string: url) }
        // Encode everything except unreserved characters, so "&", "#" and "+"
        // in a query can't break out of its parameter.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: url.replacingOccurrences(of: "{query}", with: encoded))
    }
}

public enum Quicklinks {
    public static let defaults: [Quicklink] = [
        // Searches
        Quicklink(name: "Google", url: "https://www.google.com/search?q={query}", keyword: "g"),
        Quicklink(name: "YouTube", url: "https://www.youtube.com/results?search_query={query}", keyword: "yt"),
        Quicklink(name: "GitHub", url: "https://github.com/search?q={query}&type=repositories", keyword: "gh"),
        Quicklink(name: "Wikipedia", url: "https://en.wikipedia.org/wiki/Special:Search?search={query}", keyword: "w"),
        Quicklink(name: "Stack Overflow", url: "https://stackoverflow.com/search?q={query}", keyword: "so"),
        Quicklink(name: "Go Packages", url: "https://pkg.go.dev/search?q={query}", keyword: "go"),
        Quicklink(name: "PyPI", url: "https://pypi.org/search/?q={query}", keyword: "pypi"),
        Quicklink(name: "MDN", url: "https://developer.mozilla.org/en-US/search?q={query}", keyword: "mdn"),
        // Bookmarks
        Quicklink(name: "Parliament", url: "https://am-parliament.org"),
        Quicklink(name: "Portfolio", url: "https://masonkimball.dev"),
        Quicklink(name: "My GitHub", url: "https://github.com/MasonKimball05"),
        Quicklink(name: "homebase Dashboard", url: "http://arkans-pc1:8090"),
        Quicklink(name: "Job Tracker", url: "http://arkans-pc1:5206"),
        Quicklink(name: "Sentinel Dashboard", url: "http://arkans-pc1:8484"),
        Quicklink(name: "Cloudflare Dashboard", url: "https://dash.cloudflare.com"),
        Quicklink(name: "Cloud Run (site checkup)", url: "https://console.cloud.google.com/run?project=site-checkup-510202"),
    ]

    /// "g swift actors" -> (Google, "swift actors"). Keywords are matched whole
    /// and case-insensitively; the query needs at least one character.
    public static func search(_ text: String, in links: [Quicklink]) -> (link: Quicklink, query: String)? {
        guard let space = text.firstIndex(of: " ") else { return nil }
        let keyword = text[..<space].lowercased()
        let query = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let link = links.first(where: { $0.takesQuery && $0.keyword?.lowercased() == keyword }) else { return nil }
        return (link, query)
    }
}

/// Small JSON files in ~/Library/Application Support/Hop that I can edit by hand.
public enum ConfigFile {
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Hop")
    }

    /// Loads `name`, creating it from `defaults` the first time. A file that
    /// doesn't parse is left alone (so a typo doesn't wipe my edits) and the
    /// defaults are used until it's fixed; the error says what's wrong.
    public static func load<T: Codable>(_ name: String, defaults: T, in folder: URL = folder) -> (value: T, error: String?) {
        let file = folder.appending(path: name)
        guard let data = try? Data(contentsOf: file) else {
            try? save(defaults, to: name, in: folder)
            return (defaults, nil)
        }
        do {
            return (try JSONDecoder().decode(T.self, from: data), nil)
        } catch {
            return (defaults, "\(name) has an error, so the defaults are in use: \(error.localizedDescription)")
        }
    }

    public static func save<T: Encodable>(_ value: T, to name: String, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: folder.appending(path: name), options: .atomic)
    }
}
