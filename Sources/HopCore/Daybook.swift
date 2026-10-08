import Foundation

/// Daybook, my calendar app (github.com/MasonKimball05/Daybook).
///
/// Reading: Daybook writes ~/Library/Application Support/Daybook/hop.json on
/// every refresh (the next event, the rest of today, tasks due, countdowns), and
/// hop reads it. Sending: hop opens daybook:// links, which Daybook on the Mac
/// answers by adding a task or event, logging time, checking a task off, or
/// showing a view. Daybook does the real work in both directions; hop never
/// touches Calendar or Reminders itself.
public enum Daybook {
    // MARK: The feed

    public struct Feed: Decodable, Sendable {
        public struct Event: Decodable, Sendable {
            public let title: String
            public let start: Date
            public let end: Date
            public let allDay: Bool
            public let calendar: String
            public let place: String?
        }

        public struct Task: Decodable, Sendable {
            public let id: String
            public let title: String
            public let due: Date?
            public let hasTime: Bool
            public let overdue: Bool
            public let priority: String
        }

        public struct Countdown: Decodable, Sendable {
            public let title: String
            public let date: Date
            public let days: Int
        }

        public let updated: Date
        public let today: [Event]
        public let tasks: [Task]
        public let countdowns: [Countdown]
        public let waitingOnReplies: Int
        public let codingHoursToday: Double
        public let commitsToday: Int

        /// The next timed event not over yet.
        public func next(after now: Date = .now) -> Event? {
            today.first { !$0.allDay && $0.end > now }
        }
    }

    public static var feedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Daybook/hop.json")
    }

    public static func decode(_ data: Data) -> Feed? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Feed.self, from: data)
    }

    /// The feed, or nil when Daybook isn't set up on this Mac.
    public static func readFeed() -> Feed? {
        (try? Data(contentsOf: feedURL)).flatMap(decode)
    }

    /// "in 25 min", "now", "in 2 h 5 min"
    public static func countdown(to start: Date, end: Date, now: Date = .now) -> String {
        if start <= now { return end > now ? "now" : "ended" }
        let minutes = Int(start.timeIntervalSince(now) / 60) + 1
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Typed commands

    /// What a line typed in hop asks Daybook to do.
    public enum Command: Equatable, Sendable {
        case addTask(String)                                   // "task submit report friday 3pm"
        case addEvent(String)                                  // "event coffee with Sam thu 2pm"
        case log(title: String, start: Date, end: Date)        // "log study 10-11pm"
    }

    /// Reads "task …", "todo …", "event …" and "log …" lines. A log line needs a
    /// time: a range ("10-11pm", "9:30am to 11", "2pm-3:15pm") or a length that
    /// ended now ("90m", "1.5h", "for 2h").
    public static func command(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let word = trimmed[..<space].lowercased()
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        switch word {
        case "task", "todo": return .addTask(rest)
        case "event": return .addEvent(rest)
        case "log":
            guard let (title, start, end) = logTimes(rest, now: now, calendar: calendar) else { return nil }
            return .log(title: title, start: start, end: end)
        default: return nil
        }
    }

    /// "study 10-11pm" -> ("Study", 10 PM, 11 PM today). A range that hasn't
    /// started yet is taken to be yesterday's (logging last night's study after midnight).
    static func logTimes(_ text: String, now: Date, calendar: Calendar) -> (String, Date, Date)? {
        // A range: start [am/pm] (- | – | to) end [am/pm].
        let range = #/(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/#
        if let match = text.firstMatch(of: range) {
            let endMeridiem = match.6.map { $0.lowercased() }
            // "10-11pm": the start takes the end's am/pm, unless that would put it after the end.
            let startMeridiem = match.3.map { $0.lowercased() } ?? endMeridiem
            guard let endHour = hour24(Int(match.4)!, endMeridiem), var startHour = hour24(Int(match.1)!, startMeridiem) else { return nil }
            let startMinute = match.2.flatMap { Int($0) } ?? 0, endMinute = match.5.flatMap { Int($0) } ?? 0
            if match.3 == nil, startHour * 60 + startMinute > endHour * 60 + endMinute, startHour >= 12 { startHour -= 12 } // "11-1pm"
            let day = calendar.startOfDay(for: now)
            guard var start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day),
                  var end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: day) else { return nil }
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end)! }   // past midnight
            if start > now {
                start = calendar.date(byAdding: .day, value: -1, to: start)!
                end = calendar.date(byAdding: .day, value: -1, to: end)!
            }
            return title(text, removing: match.range).map { ($0, start, end) }
        }
        // A length that just ended: "90m", "1.5h", "for 2h", "2 hours".
        let length = #/(?i)\b(?:for\s+)?(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours?|m|min|mins|minutes?)\b/#
        if let match = text.firstMatch(of: length), let amount = Double(match.1) {
            let seconds = match.2.lowercased().hasPrefix("h") ? amount * 3600 : amount * 60
            guard seconds >= 60 else { return nil }
            return title(text, removing: match.range).map { ($0, now.addingTimeInterval(-seconds), now) }
        }
        return nil
    }

    private static func hour24(_ hour: Int, _ meridiem: String?) -> Int? {
        guard (0...23).contains(hour) else { return nil }
        switch meridiem {
        case "am": return hour == 12 ? 0 : (hour <= 12 ? hour : nil)
        case "pm": return hour == 12 ? 12 : (hour < 12 ? hour + 12 : nil)
        default: return hour
        }
    }

    /// What's left once the time is cut out, capitalized: "study" -> "Study".
    private static func title(_ text: String, removing range: Range<String.Index>) -> String? {
        var rest = text
        rest.removeSubrange(range)
        let words = rest.split(separator: " ").filter { !["from", "at", "for"].contains($0.lowercased()) }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Links

    public static func link(for command: Command) -> URL {
        var components = URLComponents()
        components.scheme = "daybook"
        let iso = ISO8601DateFormatter()
        switch command {
        case .addTask(let text):
            components.host = "add-task"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .addEvent(let text):
            components.host = "add-event"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .log(let title, let start, let end):
            components.host = "log"
            components.queryItems = [URLQueryItem(name: "title", value: title),
                                     URLQueryItem(name: "start", value: iso.string(from: start)),
                                     URLQueryItem(name: "end", value: iso.string(from: end))]
        }
        return components.url!
    }

    public static func completeLink(taskID: String) -> URL {
        var components = URLComponents()
        components.scheme = "daybook"
        components.host = "complete-task"
        components.queryItems = [URLQueryItem(name: "id", value: taskID)]
        return components.url!
    }

    /// "today", "week", "month", "agenda", "tasks", "time"; or nil for the morning brief.
    public static func showLink(_ view: String?) -> URL {
        URL(string: view.map { "daybook://show?view=\($0)" } ?? "daybook://brief")!
    }
}
