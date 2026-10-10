import Foundation

/// Past Ask Claude conversations: each one saved when a new one starts, listed newest
/// first and searchable, and reopened with its Claude Code session so Claude still
/// remembers it. Generic over the message type, which lives in the app.
public struct ConversationArchive<Message: Codable & Sendable>: Sendable {
    public struct Conversation: Codable, Sendable {
        public var id: UUID
        public var title: String
        public var started: Date
        public var updated: Date
        public var sessionID: String?
        public var messages: [Message]

        public init(id: UUID, title: String, started: Date, updated: Date, sessionID: String?, messages: [Message]) {
            self.id = id
            self.title = title
            self.started = started
            self.updated = updated
            self.sessionID = sessionID
            self.messages = messages
        }
    }

    /// What the list shows, kept in one index file so listing doesn't read every conversation.
    public struct Summary: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let started: Date
        public let updated: Date
        public let count: Int
        /// The conversation's text, lowercased and shortened, for searching.
        public let text: String
    }

    public let folder: URL
    /// The most kept; the oldest go first.
    public let limit: Int

    public init(folder: URL, limit: Int = 200) {
        self.folder = folder
        self.limit = limit
    }

    private var indexFile: URL { folder.appending(path: "index.json") }
    private func file(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }

    /// Saves (or replaces) a conversation. `text` is what search looks through.
    public func save(_ conversation: Conversation, text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(to: file(conversation.id), options: .atomic)
        var index = summaries().filter { $0.id != conversation.id }
        index.append(Summary(id: conversation.id, title: conversation.title, started: conversation.started,
                             updated: conversation.updated, count: conversation.messages.count,
                             text: String(text.lowercased().prefix(8000))))
        index.sort { $0.updated > $1.updated }
        for old in index.dropFirst(limit) { try? FileManager.default.removeItem(at: file(old.id)) }
        try writeIndex(Array(index.prefix(limit)))
    }

    /// Newest first; with a query, the ones whose title or text has every word.
    public func list(matching query: String = "") -> [Summary] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return summaries().filter { summary in
            words.allSatisfy { summary.title.lowercased().contains($0) || summary.text.contains($0) }
        }
    }

    public func load(_ id: UUID) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file(id))).flatMap { try? decoder.decode(Conversation.self, from: $0) }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        try? writeIndex(summaries().filter { $0.id != id })
    }

    private func summaries() -> [Summary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = (try? Data(contentsOf: indexFile)).flatMap { try? decoder.decode([Summary].self, from: $0) } ?? []
        return index.sorted { $0.updated > $1.updated }
    }

    private func writeIndex(_ index: [Summary]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: indexFile, options: .atomic)
    }

    /// A title from the first thing asked: its first line, shortened.
    public static func title(from question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Conversation" }
        return trimmed.count > 70 ? String(trimmed.prefix(70)) + "\u{2026}" : trimmed
    }
}

/// Quizzing yourself with Ask Claude, on notes, a file, or the conversation so far.
public enum Quiz {
    /// The most material sent, about 25 pages.
    public static let maxMaterial = 60_000

    /// The opening message. With no material, the quiz is on the conversation itself.
    public static func prompt(material: String?, source: String, questions: Int = 10) -> String {
        let rules = """
            Quiz me to help me study, \(questions) questions, one at a time. Mix the kinds: short \
            answer, multiple choice (A–D), and problems to work out, harder as I get them right. \
            Ask a question, then stop and wait for my answer; don't give the answer first. After \
            I answer, say whether it's right in a sentence or two (and why, if not), keep a running \
            score like "3/4", then ask the next one. If I say "skip", give the answer and move on; \
            if I say "stop", end early. At the end, give my score and the topics I should review, \
            most important first.
            """
        guard let material else {
            return "\(rules)\n\nQuiz me on what we\u{2019}ve covered in this conversation."
        }
        let body = material.count > maxMaterial ? String(material.prefix(maxMaterial)) + "\n[\u{2026}cut off]" : material
        return "\(rules)\n\nQuiz me on \(source):\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

extension ClaudeCLI {
    /// The CLI's answer to `--resume` for a session it no longer has (Claude Code
    /// cleans up old sessions after a while).
    public static func isMissingSession(_ error: String) -> Bool {
        error.contains("No conversation found")
    }

    /// When the old session is gone: the conversation so far as text, then the new question.
    public static func continuePrompt(transcript: [(isUser: Bool, text: String)], question: String, limit: Int = 30_000) -> String {
        var lines = transcript.map { ($0.isUser ? "Me: " : "You: ") + $0.text }
        while lines.joined(separator: "\n\n").count > limit, lines.count > 1 { lines.removeFirst() }
        return """
            We talked earlier; here's that conversation, to pick up where we left off:

            \(lines.joined(separator: "\n\n"))

            Now: \(question)
            """
    }
}
