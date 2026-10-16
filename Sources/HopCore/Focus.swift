import Foundation

/// The study timer: "focus 45m calc" counts down in the menu bar and, when it ends,
/// logs the time to Daybook ("Calc", 45 minutes). The parts that can be tested.
public enum Focus {
    public struct Command: Equatable, Sendable {
        public let minutes: Int
        /// What it's for ("calc", "chem lab"); nil for a plain focus.
        public let label: String?
    }

    /// With no length given ("focus calc"), a pomodoro.
    public static let defaultMinutes = 25
    /// Shorter than this isn't worth a line in Daybook's time log.
    public static let minimumLogged: TimeInterval = 5 * 60

    /// "focus 45m calc", "study 1h30m chem lab", "focus calc 50", "focus" -> a command.
    /// The length can go anywhere: 45, 45m, 45min, 1h, 1.5h, 1h30, 1h30m.
    public static func command(_ text: String) -> Command? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased(), ["focus", "study"].contains(first) else { return nil }
        var minutes: Int?
        var label: [String] = []
        for word in words.dropFirst() {
            if minutes == nil, let length = self.minutes(in: word) { minutes = length } else { label.append(word) }
        }
        let length = minutes ?? defaultMinutes
        guard (1...12 * 60).contains(length) else { return nil }
        return Command(minutes: length, label: label.isEmpty ? nil : label.joined(separator: " "))
    }

    private static func minutes(in word: String) -> Int? {
        let lower = word.lowercased()
        if let match = lower.wholeMatch(of: #/(\d+)h(?:(\d+)m?)?/#) {
            return Int(match.1)! * 60 + (match.2.flatMap { Int($0) } ?? 0)
        }
        if let match = lower.wholeMatch(of: #/(\d+(?:\.\d+)?)(h|hr|hrs|hours?)/#), let hours = Double(match.1) {
            return Int((hours * 60).rounded())
        }
        if let match = lower.wholeMatch(of: #/(\d+)(m|min|mins|minutes?)?/#) {
            return Int(match.1)
        }
        return nil
    }

    /// The menu bar countdown: "24:13", or "1:05:00" for an hour or more.
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The Daybook time-log title: the label, capitalized, or "Focus".
    public static func logTitle(_ label: String?) -> String {
        guard let label, let first = label.first else { return "Focus" }
        return first.uppercased() + label.dropFirst()
    }

    /// "45 minutes", "1 hour", "1 h 30 min".
    public static func length(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
