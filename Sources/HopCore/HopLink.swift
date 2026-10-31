import Foundation

/// hop:// links, so other apps (Eclipse's ⌘T, Daybook, a Shortcut) can tell Hop what to
/// do. Anything can open a link, a web page included (the browser asks first), so no
/// link spends Claude usage by itself: an "ask" link fills in the question and attaches
/// the page, and you press Return.
public enum HopLink: Equatable, Sendable {
    /// hop://open?q=… : the launcher, with that typed.
    case open(query: String?)
    /// hop://ask?q=…&page=<url>&title=…&text=… : Ask Claude, with a page (its text from
    /// Eclipse's index) or some text attached, and the question filled in.
    case ask(question: String?, page: String?, title: String?, text: String?)
    /// hop://focus?minutes=45&label=calc : the study timer.
    case focus(minutes: Int, label: String?)
    /// hop://deadlines?page=<url>&title=… : due dates from a page's text into Daybook.
    case deadlines(page: String?, title: String?)
    /// hop://brief : today's Daybook brief.
    case brief

    public static let scheme = "hop"
    /// The most text a link can attach.
    public static let maxText = 20_000

    public static func parse(_ url: URL) -> HopLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { values[item.name] = value }
        }
        // Only web pages: a link can't point Hop at a file on the Mac.
        let page = values["page"].flatMap { URL(string: $0)?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true ? values["page"] : nil }
        switch action {
        case "", "open":
            return .open(query: values["q"])
        case "ask":
            return .ask(question: values["q"], page: page, title: values["title"], text: values["text"].map { String($0.prefix(maxText)) })
        case "focus":
            let minutes = values["minutes"].flatMap(Int.init) ?? Focus.defaultMinutes
            guard (1...12 * 60).contains(minutes) else { return nil }
            return .focus(minutes: minutes, label: values["label"])
        case "deadlines", "due-dates":
            return .deadlines(page: page, title: values["title"])
        case "brief":
            return .brief
        default:
            return nil
        }
    }
}
