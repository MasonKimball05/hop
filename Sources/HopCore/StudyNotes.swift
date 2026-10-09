import Foundation

/// Ask Claude's study notes: with notes on, each answered question is added to a
/// Markdown file for the day, and Make Study Guide adds a review sheet at the end.
public struct StudyNotes: Sendable {
    public let folder: URL

    /// ~/Documents/Hop Notes, unless set with
    /// `defaults write com.masonkimball.Hop notesFolder /some/folder`.
    public static var defaultFolder: URL {
        if let custom = UserDefaults.standard.string(forKey: "notesFolder"), !custom.isEmpty {
            return URL(filePath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Hop Notes")
    }

    public init(folder: URL = StudyNotes.defaultFolder) {
        self.folder = folder
    }

    public static let studyGuidePrompt = """
        Write a short study guide from this conversation, for reviewing before a test. \
        For each problem or topic we covered: the key idea or method, the steps in brief, \
        and mistakes to watch for. Group similar problems together. Use Markdown: a ### \
        heading per topic, then short bullet points. Don't repeat whole worked solutions.
        """

    /// One file per day: "2026-10-09.md".
    public func file(for date: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return folder.appending(path: String(format: "%04d-%02d-%02d.md", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    }

    /// The Markdown for one answered question.
    public static func entry(question: String, answer: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let heading = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        let short = heading.count > 90 ? String(heading.prefix(90)) + "\u{2026}" : heading
        return "## \(time(date, timeZone)) \u{00B7} \(short)\n\n\(answer.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
    }

    public static func studyGuide(_ guide: String, at date: Date, timeZone: TimeZone = .current) -> String {
        "## Study guide (\(time(date, timeZone)))\n\n\(guide.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
    }

    /// Adds `markdown` to the day's file, starting it with a title if it's new.
    /// Returns the file.
    @discardableResult
    public func append(_ markdown: String, at date: Date = .now) throws -> URL {
        let file = file(for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            try Data("# Study notes, \(formatter.string(from: date))\n\n".utf8).write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(markdown.utf8))
        return file
    }

    private static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
