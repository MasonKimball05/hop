import Foundation
import SQLite3

/// Eclipse, my web browser (github.com/MasonKimball05/Eclipse).
///
/// Reading: Eclipse saves its tabs, Spaces and history to session.json (atomically, so
/// a read never sees half a file) and indexes the text of pages you visit in pages.db.
/// Hop reads both and never writes them. Sending: eclipse-browser:// links open a page
/// or switch Space, and Eclipse's AppleScript commands (in Hop) bring up or close an
/// exact tab. Passwords, passkeys and addresses live elsewhere in the folder and are
/// never touched.
public enum Eclipse {
    public static let bundleIDs = ["com.masonkimball.eclipse", "com.masonkimball.eclipse.dev"]
    public static let scheme = "eclipse-browser"

    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MasonKimball05/Eclipse")
    }

    // MARK: The session

    public struct Space: Equatable, Sendable {
        public let id: String
        public let name: String
        /// An emoji, or an icon name like "ph.planet".
        public let icon: String?
    }

    public struct Tab: Equatable, Sendable {
        public enum Section: String, Sendable { case favorites = "Favorites", pinned = "Pinned", today = "Today" }
        public let id: String
        public let url: String
        public let title: String
        /// nil for a Favorite, which every Space shares.
        public let space: String?
        public let section: Section
        public let lastActive: Date?

        public var host: String { URL(string: url)?.host() ?? url }
    }

    public struct Visit: Equatable, Sendable {
        public let url: String
        public let title: String
        public let date: Date
        public let visits: Int
    }

    /// A tab Eclipse tidied away after 12 hours unused.
    public struct Archived: Equatable, Sendable {
        public let url: String
        public let title: String
        /// nil when its Space has gone since.
        public let space: String?
        public let date: Date
    }

    /// A folder that fills itself from a feed. `new` are the items you haven't looked
    /// at yet, as Eclipse counts them (an item whose address isn't in its "seen" list).
    public struct LiveFolder: Equatable, Sendable {
        public let id: String
        public let name: String
        public let space: String?
        public let new: [Item]

        public struct Item: Equatable, Sendable {
            public let title: String
            public let url: String
        }
    }

    /// A page Eclipse checks for changes ("Watch for Changes…").
    public struct PageWatch: Equatable, Sendable {
        public let id: String
        public let url: String
        public let title: String
        /// When it last changed; nil if it never has.
        public let changed: Date?
        /// What changed, in a line ("Price dropped to $249").
        public let summary: String
        public let paused: Bool
    }

    public struct Session: Sendable {
        public let spaces: [Space]
        public let tabs: [Tab]
        /// Newest first.
        public let history: [Visit]
        public var activeSpace: String? = nil
        public var archived: [Archived] = []
        public var liveFolders: [LiveFolder] = []
        public var pageWatches: [PageWatch] = []
    }

    /// Reads session.json. Lenient: an entry missing a field is skipped, not the file.
    public static func session(from data: Data) -> Session? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var spaces: [Space] = []
        var tabs: [Tab] = []
        var liveFolders: [LiveFolder] = []

        func collect(_ items: Any?, space: String?, section: Tab.Section) {
            for item in items as? [[String: Any]] ?? [] {
                if item["type"] as? String == "folder" {
                    if let live = item["live"] as? [String: Any] { liveFolders.append(liveFolder(item, live: live, space: space)) }
                    collect(item["children"], space: space, section: section)
                    continue
                }
                guard let id = item["id"] as? String, let url = item["url"] as? String, !url.isEmpty else { continue }
                let custom = (item["custom_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let title = custom ?? (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                tabs.append(Tab(id: id, url: url, title: title, space: space, section: section,
                                lastActive: date(item["last_active"])))
            }
        }

        collect(root["favorites"], space: nil, section: .favorites)
        for item in root["spaces"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
            spaces.append(Space(id: id, name: name, icon: item["icon"] as? String))
            collect(item["pinned"], space: name, section: .pinned)
            collect(item["today"], space: name, section: .today)
        }
        let history = (root["history"] as? [[String: Any]] ?? []).compactMap { item -> Visit? in
            guard let url = item["url"] as? String, let when = date(item["ts"]) else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            return Visit(url: url, title: title, date: when, visits: item["visits"] as? Int ?? 1)
        }
        let names = Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let archived = (root["archive"] as? [[String: Any]] ?? []).compactMap { item -> Archived? in
            guard let url = item["url"] as? String, let when = date(item["archived_at"]) else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            return Archived(url: url, title: title, space: (item["space_id"] as? String).flatMap { names[$0] }, date: when)
        }.sorted { $0.date > $1.date }
        let settings = root["settings"] as? [String: Any] ?? [:]
        let watches = (settings["page_watches"] as? [[String: Any]] ?? []).compactMap { item -> PageWatch? in
            guard let id = item["id"] as? String, let url = item["url"] as? String else { return nil }
            return PageWatch(id: id, url: url, title: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url,
                             changed: date(item["changed"]), summary: item["summary"] as? String ?? "",
                             paused: item["paused"] as? Bool ?? false)
        }
        var session = Session(spaces: spaces, tabs: tabs, history: history)
        session.activeSpace = (root["active_space_id"] as? String).flatMap { names[$0] }
        session.archived = archived
        session.liveFolders = liveFolders
        session.pageWatches = watches
        return session
    }

    /// A Live Folder and its items not yet looked at: its tabs (in sub-folders too) whose
    /// feed address (home_url, else url) isn't in live["seen"].
    private static func liveFolder(_ folder: [String: Any], live: [String: Any], space: String?) -> LiveFolder {
        let seen = Set(live["seen"] as? [String] ?? [])
        var new: [LiveFolder.Item] = []
        func walk(_ items: Any?) {
            for item in items as? [[String: Any]] ?? [] {
                if item["type"] as? String == "folder" { walk(item["children"]); continue }
                let home = (item["home_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard let key = home ?? item["url"] as? String, !seen.contains(key) else { continue }
                let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
                new.append(LiveFolder.Item(title: title, url: key))
            }
        }
        // Before its first refresh, Eclipse counts everything already there as seen.
        if live["refreshed"] != nil { walk(folder["children"]) }
        return LiveFolder(id: folder["id"] as? String ?? UUID().uuidString, name: folder["name"] as? String ?? "Live Folder",
                          space: space, new: new)
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let text = value as? String, let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    // MARK: Typed commands

    /// "tab calc", "tabs" -> the search ("" for every tab).
    public static func tabQuery(_ text: String) -> String? { rest(of: text, after: ["tab", "tabs"], allowEmpty: true) }
    /// "space school" -> "school".
    public static func spaceQuery(_ text: String) -> String? { rest(of: text, after: ["space", "spaces"], allowEmpty: true) }
    /// "h swift concurrency", "history swift" -> the search.
    public static func historyQuery(_ text: String) -> String? { rest(of: text, after: ["h", "history"], allowEmpty: false) }
    /// "archive canvas", "archived" -> the search ("" for all).
    public static func archiveQuery(_ text: String) -> String? { rest(of: text, after: ["archive", "archived"], allowEmpty: true) }
    /// "note essay ideas", "notes" -> the search ("" for all).
    public static func noteQuery(_ text: String) -> String? { rest(of: text, after: ["note", "notes"], allowEmpty: true) }
    /// "page diffie hellman" -> the search.
    public static func pageQuery(_ text: String) -> String? { rest(of: text, after: ["page", "pages"], allowEmpty: false) }

    private static func rest(of text: String, after words: [String], allowEmpty: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for word in words {
            if lower == word { return allowEmpty ? "" : nil }
            if lower.hasPrefix(word + " ") {
                let rest = trimmed.dropFirst(word.count + 1).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty && !allowEmpty ? nil : rest
            }
        }
        return nil
    }

    // MARK: Searching

    /// Tabs whose title, address or Space matches every word, most recently used first.
    public static func tabs(matching query: String, in session: Session) -> [Tab] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return session.tabs
            .filter { tab in
                let haystack = "\(tab.title) \(tab.url) \(tab.space ?? "Favorites")".lowercased()
                return words.allSatisfy(haystack.contains)
            }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// History entries whose title or address matches every word, one per address,
    /// most visited first among the most recent.
    public static func history(matching query: String, in session: Session, limit: Int = 30) -> [Visit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var seen = Set<String>()
        var out: [Visit] = []
        for visit in session.history where words.allSatisfy("\(visit.title) \(visit.url)".lowercased().contains) {
            guard seen.insert(visit.url).inserted else { continue }
            out.append(visit)
            if out.count == limit { break }
        }
        return out
    }

    /// Archived tabs matching every word, most recently archived first.
    public static func archived(matching query: String, in session: Session) -> [Archived] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return session.archived.filter { item in
            words.allSatisfy("\(item.title) \(item.url) \(item.space ?? "")".lowercased().contains)
        }
    }

    // MARK: Notes

    public struct Note: Equatable, Sendable {
        public let id: String
        /// Its first line, without the "# ".
        public let title: String
        public let text: String
        public let modified: Date
    }

    /// The notes in notes/<id>.md, newest first.
    public static func notes(in folder: URL = folder.appending(path: "notes")) -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { file -> Note? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let title = first.replacing(#/^#+\s*/#) { _ in "" }.trimmingCharacters(in: .whitespaces)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Note(id: file.deletingPathExtension().lastPathComponent, title: title.isEmpty ? "Untitled Note" : title,
                        text: text, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// Notes whose text has every word.
    public static func notes(matching query: String, in notes: [Note]) -> [Note] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return notes.filter { note in words.allSatisfy(note.text.lowercased().contains) }
    }

    // MARK: Focus sessions

    /// The "focusSpace" setting: switch only when the label names a Space.
    public static let focusSpaceFromLabel = ""
    /// The "focusSpace" setting: never switch.
    public static let focusSpaceNever = "-"

    /// Which Space a focus session moves Eclipse to: the one its label names ("focus
    /// school", or "calc in School"), else the Space set for focus sessions, if any.
    public static func focusSpace(label: String?, setting: String, spaces: [Space]) -> String? {
        guard setting != focusSpaceNever else { return nil }
        if let label = label?.lowercased(),
           let named = spaces.first(where: { label == $0.name.lowercased() || label.split(separator: " ").contains(Substring($0.name.lowercased())) }) {
            return named.name
        }
        return spaces.first { $0.name == setting }?.name
    }

    // MARK: Links

    /// Opens an http(s) page in Eclipse, in a Space when given.
    public static func openLink(_ page: String, space: String? = nil) -> URL? {
        guard let scheme = URL(string: page)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return link("open", ["url": page, "space": space])
    }

    public static func spaceLink(_ name: String) -> URL? { link("space", ["name": name]) }

    /// Opens one of Eclipse's notes (its "note" link, added for Hop).
    public static func noteLink(_ id: String) -> URL? { link("note", ["id": id]) }

    public static func searchLink(_ query: String, space: String? = nil) -> URL? { link("search", ["q": query, "space": space]) }

    private static func link(_ action: String, _ values: [String: String?]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = values.keys.sorted().compactMap { key in values[key]!.map { URLQueryItem(name: key, value: $0) } }
        // Eclipse reads these with parse_qs, which turns a bare "+" into a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: Pages you've read

    public struct PageHit: Equatable, Sendable {
        public let url: String
        public let title: String
        /// The matching text, with the matched words between « and ».
        public let snippet: String
    }

    /// The words as an FTS5 query: each quoted (so punctuation can't break it), the last
    /// one a prefix so results come while typing.
    public static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard let last = words.last else { return nil }
        return (words.dropLast().map { "\"\($0)\"" } + ["\"\(last)\"*"]).joined(separator: " ")
    }

    /// Searches the text of pages Eclipse has indexed.
    public static func searchPages(_ text: String, database: URL = folder.appending(path: "pages.db"), limit: Int = 20) -> [PageHit] {
        guard let match = ftsQuery(text) else { return [] }
        return withCopy(of: database) { db in pages(db, matching: match, limit: limit) } ?? []
    }

    /// A page's whole text as Eclipse indexed it (up to 30,000 characters), for asking
    /// about it. nil when it isn't indexed: a private window, a page with a password
    /// field, or a site Eclipse skips (banks, health, mail).
    public static func pageText(for url: String, database: URL = folder.appending(path: "pages.db")) -> (title: String, text: String)? {
        withCopy(of: database) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT title, body FROM pages WHERE url = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, url, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let body = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            return body.isEmpty ? nil : (title.isEmpty ? url : title, body)
        } ?? nil
    }

    /// Runs `work` on a copy of pages.db (and its WAL file): Eclipse keeps the database
    /// open in WAL mode, which a read-only open can't share when Eclipse isn't running,
    /// and a copy never gets in its way.
    private static func withCopy<T>(of database: URL, _ work: (OpaquePointer?) -> T) -> T? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let copy = FileManager.default.temporaryDirectory.appending(path: "hop-eclipse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            for suffix in ["", "-wal"] {
                let source = URL(filePath: database.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: copy.appending(path: "pages.db" + suffix))
                }
            }
        } catch {
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.appending(path: "pages.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return work(db)
    }

    private static func pages(_ db: OpaquePointer?, matching match: String, limit: Int) -> [PageHit] {
        let sql = "SELECT url, title, snippet(pages, 2, '«', '»', '…', 12) FROM pages WHERE pages MATCH ?1 ORDER BY rank LIMIT ?2"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, match, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [PageHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
            let snippet = column(2).split(whereSeparator: \.isNewline).joined(separator: " ")
            hits.append(PageHit(url: column(0), title: column(1).isEmpty ? column(0) : column(1), snippet: snippet))
        }
        return hits
    }
}
