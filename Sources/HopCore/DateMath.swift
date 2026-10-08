import Foundation

/// Dates and times in plain words:
///   "time in berlin", "tokyo time"         the time somewhere else right now
///   "3pm cst in pst", "15:00 berlin to et" a time converted between zones
///   "days until may 15 2027", "days since jan 1"
///   "30 days from now", "2 weeks ago", "90 days from may 15 2027"
///   "unix" (now as a Unix timestamp), "1790745691" (a timestamp as a date)
public struct DateMath: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = .now, timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    public func evaluate(_ input: String) -> Calculator.Answer? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty else { return nil }
        return unixNow(text) ?? timestamp(text) ?? timeIn(text) ?? convertTime(text) ?? daysBetween(text) ?? offset(text)
    }

    // MARK: Unix time

    private func unixNow(_ text: String) -> Calculator.Answer? {
        guard ["unix", "timestamp", "now in unix", "unix time", "epoch"].contains(text) else { return nil }
        return .init(text: String(Int(now.timeIntervalSince1970)), detail: "Now as a Unix timestamp")
    }

    /// 10 digits (seconds) or 13 (milliseconds) between 2001 and 2100.
    private func timestamp(_ text: String) -> Calculator.Answer? {
        guard text.allSatisfy(\.isNumber), text.count == 10 || text.count == 13, let n = Double(text) else { return nil }
        let seconds = text.count == 13 ? n / 1000 : n
        guard seconds > 978_307_200, seconds < 4_102_444_800 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return .init(text: format(date, in: timeZone, style: .full), detail: "Unix timestamp \(text)")
    }

    // MARK: Time zones

    private func timeIn(_ text: String) -> Calculator.Answer? {
        var place: String?
        if text.hasPrefix("time in ") { place = String(text.dropFirst("time in ".count)) }
        else if text.hasSuffix(" time") { place = String(text.dropLast(" time".count)) }
        guard let place, let zone = Self.zone(named: place) else { return nil }
        return .init(text: format(now, in: zone, style: .timeWithDay), detail: "Now in \(Self.label(place, zone))")
    }

    /// "<time> [zone] in|to <zone>". Without a source zone, the time is local.
    private func convertTime(_ text: String) -> Calculator.Answer? {
        guard let separator = [" in ", " to "].compactMap({ text.range(of: $0) }).first else { return nil }
        let left = text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let targetName = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let target = Self.zone(named: targetName) else { return nil }

        // Try the longest prefix that parses as a time; the rest is the source zone.
        let words = left.split(separator: " ").map(String.init)
        for split in stride(from: words.count, through: 1, by: -1) {
            let timeText = words[..<split].joined(separator: " ")
            let zoneText = words[split...].joined(separator: " ")
            guard let (hour, minute) = Self.parseTime(timeText) else { continue }
            let source = zoneText.isEmpty ? timeZone : Self.zone(named: zoneText)
            guard let source else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = source
            var parts = calendar.dateComponents([.year, .month, .day], from: now)
            parts.hour = hour
            parts.minute = minute
            guard let date = calendar.date(from: parts) else { return nil }
            let sourceLabel = zoneText.isEmpty ? "local" : Self.label(zoneText, source)
            return .init(text: format(date, in: target, style: .timeWithDay),
                         detail: "\(timeText) \(sourceLabel) in \(Self.label(targetName, target))")
        }
        return nil
    }

    /// "3pm", "3:30 pm", "15:00", "noon", "midnight".
    static func parseTime(_ text: String) -> (Int, Int)? {
        if text == "noon" { return (12, 0) }
        if text == "midnight" { return (0, 0) }
        var t = text.replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where t.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            t = String(t.dropLast(suffix.count))
            break
        }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let h = Int(parts[0]) else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let m, (0..<60).contains(m) else { return nil }
        if let meridiem {
            guard (1...12).contains(h) else { return nil }
            return (meridiem == "p" ? (h % 12) + 12 : h % 12, m)
        }
        // "3" alone is too ambiguous to be a time; "15:00" isn't.
        guard parts.count == 2, (0..<24).contains(h) else { return nil }
        return (h, m)
    }

    static let abbreviations: [String: String] = [
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver", "mountain": "America/Denver",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago", "central": "America/Chicago",
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York", "eastern": "America/New_York",
        "utc": "UTC", "gmt": "UTC", "z": "UTC",
        "cet": "Europe/Berlin", "cest": "Europe/Berlin", "bst": "Europe/London",
        "jst": "Asia/Tokyo", "ist": "Asia/Kolkata", "aest": "Australia/Sydney",
        // Places that matter to me, and nicknames the zone database doesn't have.
        "birmingham": "America/Chicago", "dallas": "America/Chicago", "samford": "America/Chicago",
        "nyc": "America/New_York", "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "germany": "Europe/Berlin", "munich": "Europe/Berlin",
        "hamburg": "Europe/Berlin", "frankfurt": "Europe/Berlin", "cologne": "Europe/Berlin",
    ]

    /// An abbreviation, nickname, or any city in the zone database ("berlin", "new york").
    static func zone(named raw: String) -> TimeZone? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name == "local" || name == "here" { return .current }
        if let id = abbreviations[name] { return TimeZone(identifier: id) }
        let wanted = name.replacingOccurrences(of: " ", with: "_")
        for id in TimeZone.knownTimeZoneIdentifiers where id.lowercased().split(separator: "/").last == Substring(wanted) {
            return TimeZone(identifier: id)
        }
        return nil
    }

    private static func label(_ name: String, _ zone: TimeZone) -> String {
        name.count <= 4 ? name.uppercased() : name.capitalized
    }

    // MARK: Days between

    private func daysBetween(_ text: String) -> Calculator.Answer? {
        let forms: [(prefix: String, future: Bool)] = [("days until ", true), ("days till ", true), ("days to ", true),
                                                       ("days since ", false), ("days from ", false)]
        guard let form = forms.first(where: { text.hasPrefix($0.prefix) }),
              let target = parseDate(String(text.dropFirst(form.prefix.count))) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        let count = abs(days)
        var answer = "\(count) day\(count == 1 ? "" : "s")"
        if count >= 14 { answer += " (\(Calculator.format((Double(count) / 7 * 10).rounded() / 10)) weeks)" }
        return .init(text: answer, detail: (days >= 0 ? "Until " : "Since ") + format(target, in: timeZone, style: .date))
    }

    // MARK: Offsets

    /// "<n> <unit> from now|today|<date>", "<n> <unit> ago".
    private func offset(_ text: String) -> Calculator.Answer? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 3, let n = Int(words[0]) else { return nil }
        let units: [String: Calendar.Component] = ["day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
                                                   "month": .month, "months": .month, "year": .year, "years": .year]
        guard let unit = units[words[1]] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let base: Date
        let sign: Int
        if words[2] == "ago" && words.count == 3 {
            base = now
            sign = -1
        } else if words[2] == "from" || words[2] == "after" {
            let rest = words.dropFirst(3).joined(separator: " ")
            guard let parsed = (rest == "now" || rest == "today") ? now : parseDate(rest) else { return nil }
            base = parsed
            sign = 1
        } else if words[2] == "before" {
            guard let parsed = parseDate(words.dropFirst(3).joined(separator: " ")) else { return nil }
            base = parsed
            sign = -1
        } else {
            return nil
        }
        guard let result = calendar.date(byAdding: unit, value: sign * n, to: base) else { return nil }
        return .init(text: format(result, in: timeZone, style: .date), detail: text)
    }

    /// Natural-language dates via NSDataDetector ("may 15 2027", "next friday", "jan 1").
    func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "today" || trimmed == "now" { return now }
        guard !trimmed.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        // The detector resolves partial dates ("jan 1") relative to the real clock,
        // which is fine for use and close enough for tests that pass a recent `now`.
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              match.range.length >= range.length - 1 else { return nil }
        return match.date
    }

    // MARK: Formatting

    enum Style { case full, timeWithDay, date }

    private func format(_ date: Date, in zone: TimeZone, style: Style) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        switch style {
        case .full: f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a zzz"
        case .timeWithDay: f.dateFormat = "h:mm a zzz, EEE"
        case .date: f.dateFormat = "EEEE, MMMM d, yyyy"
        }
        return f.string(from: date)
    }
}
