import Foundation

/// Asks Claude about the screen through the `claude` command-line tool (Claude Code)
/// in its stream-json mode. It signs in with the Claude account already logged in
/// there, so there's no API key to manage.
public enum ClaudeCLI {
    /// Where the CLI usually lives: an explicit path first, then Homebrew, then the
    /// native installer. A GUI app doesn't get the shell's PATH, so it looks itself.
    public static func locate(override: String? = nil, home: String = NSHomeDirectory(),
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let candidates = [override, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.local/bin/claude", home + "/.claude/local/claude"]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && isExecutable($0) }.map { URL(filePath: $0) }
    }

    public static let systemPrompt = """
        You are running inside Hop, a Mac launcher, as a helper the user can ask about \
        what they're doing. Each message may include a screenshot of their screen as it \
        is right now (Hop's own window is left out). Answer like a friend looking over \
        their shoulder: short and specific, one step at a time, naming the actual buttons, \
        menus and labels you can see and where they are. If the screenshot doesn't show \
        what they need, say what to open or scroll to. You can't click or type for them, \
        and you have no tools, so don't offer to run anything.
        """

    /// Added to the system prompt while tutor mode is on: for studying, where the point
    /// is learning to do it, not getting it done.
    public static let tutorPrompt = """
        Tutor mode is on: the user is studying and wants to learn to do this themselves. \
        Don't give final answers or complete solutions. Say what the question is asking \
        and which idea or method applies, then guide one step at a time and ask them to \
        try the next step. When they show their work or an answer, check it: say whether \
        it's right, and if not, point to where it went wrong without fixing it for them. \
        If they're stuck after trying, work a similar but different example instead of \
        theirs.
        """

    /// Arguments for one turn. `--tools ""` keeps it advice-only (it can't run commands
    /// or touch files) and `--strict-mcp-config` skips starting MCP servers, which is
    /// most of the CLI's startup time. The system prompt is sent every turn, so tutor
    /// mode can change partway through a conversation.
    /// `persist: false` is for one-off requests (reading due dates) that shouldn't be
    /// saved as a conversation.
    public static func arguments(resuming sessionID: String?, model: String?, tutor: Bool = false, persist: Bool = true) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config",
                    "--append-system-prompt", tutor ? systemPrompt + "\n\n" + tutorPrompt : systemPrompt]
        if let model, !model.isEmpty { args += ["--model", model] }
        if !persist { args.append("--no-session-persistence") }
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    /// One user turn as a stream-json line: the screenshot (a JPEG), then the question.
    public static func inputLine(question: String, screenshot: Data?) -> Data {
        var content: [[String: Any]] = []
        if let screenshot {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshot.base64EncodedString()]])
        }
        content.append(["type": "text", "text": question])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        // Only strings, arrays and dictionaries go in, so this can't fail.
        var data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        data.append(0x0A)
        return data
    }

    public enum Event: Equatable, Sendable {
        /// The session to `--resume` for a follow-up.
        case started(sessionID: String)
        /// A piece of the answer as it's written.
        case textDelta(String)
        /// A whole assistant message, which repeats the deltas before it.
        case message(String)
        /// The end of the turn: the full answer, or what went wrong.
        case finished(sessionID: String?, result: String, isError: Bool)
    }

    /// Reads one line of `--output-format stream-json`. Hook, retry and other
    /// bookkeeping lines return nil.
    public static func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return nil }
            return .started(sessionID: id)
        case "stream_event":
            guard let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .textDelta(text)
        case "assistant":
            guard let message = json["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return nil }
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : .message(text)
        case "result":
            return .finished(sessionID: json["session_id"] as? String, result: json["result"] as? String ?? "",
                             isError: json["is_error"] as? Bool ?? (json["subtype"] as? String != "success"))
        default:
            return nil
        }
    }

    /// A friendlier version of the CLI's error, with the fix when it's a sign-in problem.
    public static func explain(_ error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("authenticate") || lower.contains("401") || lower.contains("/login") || lower.contains("not logged in") {
            return "Claude Code isn\u{2019}t signed in. Run `claude` in a terminal, type `/login`, then ask again.\n\n(\(error))"
        }
        return error
    }

    // MARK: Explain selection

    /// The most of a selection sent; a whole selected page is still well under this.
    public static let maxSelection = 20_000

    /// The question sent for Explain Selection.
    public static func explainPrompt(_ selection: String, app: String?) -> String {
        let text = selection.count > maxSelection ? String(selection.prefix(maxSelection)) + "\n[\u{2026}cut off]" : selection
        let source = app.map { " in \($0)" } ?? ""
        return """
            Explain this, which I selected\(source). Keep it short and plain: what it means, \
            and anything I'd need to know to use it. If it's code or an error, say what it \
            does or what went wrong.

            \(text)
            """
    }

    /// How a selection shows in the conversation: its start, on one line.
    public static func selectionPreview(_ selection: String, length: Int = 140) -> String {
        let flat = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > length ? String(flat.prefix(length)) + "\u{2026}" : flat
    }

    // MARK: Watch mode

    /// What Claude replies when a new screenshot has nothing new to help with. Hop
    /// hides that turn instead of showing it.
    public static let nothingNew = "NOTHING_NEW"

    public static let watchStartPrompt = """
        I'm turning on watch mode: I'm working through what's on my screen, probably \
        several questions in a row. Help with the question or questions you can see now. \
        From here on Hop will send you a new screenshot by itself whenever my screen \
        changes, without a message from me.
        """

    public static let watchUpdatePrompt = """
        (Watch mode: my screen changed; this is the new screenshot, sent automatically.) \
        If it shows a question or problem you haven't already helped with in this \
        conversation, help with it now, saying which one it is. If not (I'm scrolling, \
        typing my answer, or it's one you've covered), reply with exactly \(nothingNew) \
        and nothing else.
        """

    /// True while a watch reply could still turn out to be `nothingNew`, so Hop
    /// waits before showing it.
    public static func mightBeNothingNew(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return nothingNew.hasPrefix(trimmed) || trimmed.hasPrefix(nothingNew)
    }

    /// "ask how do I …" or "? how do I …" in the main search -> the question.
    public static func question(fromCommand text: String) -> String? {
        for prefix in ["ask ", "? "] where text.lowercased().hasPrefix(prefix) {
            let question = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? nil : question
        }
        return nil
    }
}
