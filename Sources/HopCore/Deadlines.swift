import Foundation

/// Due dates read off the screen (a syllabus, an assignment list) by Claude, then
/// added to Daybook as tasks after you've looked them over.
public enum Deadlines {
    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        /// "2026-10-24T23:59", or "2026-10-24" when no time is given.
        public var due: String

        public init(title: String, due: String) {
            self.title = title
            self.due = due
        }
    }

    public static func prompt(now: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let today = formatter.string(from: now)
        return """
            Find every due date on this screen: assignments, problem sets, quizzes, exams, \
            projects, readings due, and any other deadline. Today is \(today); when a date \
            has no year, use the one that makes sense from today.

            Reply with only a JSON array and nothing else, like:
            [{"title": "Calc II: Problem Set 5", "due": "2026-10-24T23:59"}]

            "title" is short and starts with the course when the screen shows it. "due" is \
            YYYY-MM-DDTHH:MM in 24-hour time, or YYYY-MM-DD when no time is given. List each \
            deadline once. If there are none, reply [].
            """
    }

    /// The items in Claude's reply, or nil when it isn't the JSON asked for. Tolerates
    /// a code fence or a sentence around the array.
    public static func parse(_ reply: String) -> [Item]? {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let items = try? JSONDecoder().decode([Item].self, from: Data(reply[start...end].utf8)) else { return nil }
        return items.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && date($0) != nil }
    }

    /// When it's due, and whether a time was given.
    public static func date(_ item: Item, timeZone: TimeZone = .current) -> (date: Date, hasTime: Bool)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd", false)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: item.due) { return (date, hasTime) }
        }
        return nil
    }

    /// The text for Daybook's add-task link. The date goes first: Daybook takes the
    /// first date it finds, and titles like "Read 3.2" or "HW 10/31" look like dates.
    public static func quickAddText(_ item: Item, timeZone: TimeZone = .current) -> String? {
        guard let (date, hasTime) = date(item, timeZone: timeZone) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = hasTime ? "MMM d, yyyy h:mm a" : "MMM d, yyyy"
        return formatter.string(from: date) + " " + item.title
    }
}
