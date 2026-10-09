import AppKit
import HopCore
import Observation

/// The Ask Claude conversation: each question goes to the `claude` CLI with a fresh
/// screenshot, and follow-ups resume the same session so it remembers the earlier ones.
/// The conversation is saved, so it survives Hop restarting, and starts over on its
/// own after a few hours untouched (a short-term memory for one sitting).
///
/// Watch mode sends the screen by itself whenever it changes and settles, for working
/// through several questions without typing each time.
@MainActor
@Observable
final class AskModel {
    struct Message: Identifiable, Codable {
        /// `watch` marks a screenshot watch mode sent on its own; `note` marks a change
        /// of mode, like tutor mode turning on; `deadlines` is a list of due dates to
        /// check over and add to Daybook.
        enum Role: String, Codable { case user, claude, error, watch, note, deadlines }
        var id = UUID()
        let role: Role
        var text: String
        var withScreen = false
        var deadlines: [Deadlines.Item]?
        /// How many of `deadlines` went to Daybook; nil until they're added.
        var added: Int?
        /// The SF Symbol on a `note` divider.
        var symbol: String?
    }

    private(set) var messages: [Message] = []
    var draft = ""
    /// Send a screenshot with each question. Off for follow-ups that don't need one.
    var includeScreen = true
    private(set) var isRunning = false
    private(set) var isWatching = false
    /// Add each answered question to today's study notes file.
    var isTakingNotes = UserDefaults.standard.bool(forKey: "askNotes") {
        didSet { UserDefaults.standard.set(isTakingNotes, forKey: "askNotes") }
    }
    @ObservationIgnored private let notes = StudyNotes()
    /// An area of the screen picked with Ask About Area, sent with the next question
    /// in place of a screenshot.
    private(set) var area: ScreenCapture.Shot?
    /// Guide and check instead of answering. Kept between conversations.
    var isTutoring = UserDefaults.standard.bool(forKey: "askTutorMode") {
        didSet {
            UserDefaults.standard.set(isTutoring, forKey: "askTutorMode")
            if !messages.isEmpty {
                messages.append(Message(role: .note, text: isTutoring ? "Tutor mode on" : "Tutor mode off", symbol: "graduationcap"))
                save()
            }
        }
    }
    /// Bumped whenever the panel is shown, so the view can refocus the field.
    private(set) var focusCount = 0

    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var lastActivity = Date.now
    /// Bumped by New Chat, so a turn still finishing can't write into the new one.
    @ObservationIgnored private var chat = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var screenWatch = ScreenWatch()

    /// Set by the app delegate.
    var close: () -> Void = {}
    var isPanelVisible: () -> Bool = { false }

    init() { restore() }

    func didShow() {
        if !isRunning && !isFresh { newChat() }
        focusCount += 1
    }

    func send(_ text: String? = nil) {
        var question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // With an area attached, Return on its own asks about it.
        if question.isEmpty && area != nil { question = "What's this? Help me with it." }
        guard !question.isEmpty, !isRunning else { return }
        draft = ""
        ask(question, showing: question, withScreen: includeScreen || isWatching)
    }

    /// Attaches an area of the screen to the next question.
    func attach(area image: CGImage) {
        do {
            area = try ScreenCapture.shot(area: image)
            focusCount += 1
        } catch {
            fail(error.localizedDescription)
        }
    }

    func removeArea() { area = nil }

    /// Explains text selected in another app. No screenshot: the text is the question.
    func explain(_ selection: String?, from app: String?) {
        guard let selection else {
            return fail("Nothing selected. Select some text in any app, then press \u{2303}\u{2325}E.")
        }
        guard !isRunning else { return fail("Still answering; try again when it\u{2019}s done.") }
        ask(ClaudeCLI.explainPrompt(selection, app: app),
            showing: "Explain \u{201C}\(ClaudeCLI.selectionPreview(selection))\u{201D}", withScreen: false)
    }

    /// Sends `prompt`, shown in the conversation as `shown`. `onAnswer` gets the reply
    /// in place of the usual notes entry.
    private func ask(_ prompt: String, showing shown: String, withScreen: Bool, shot given: ScreenCapture.Shot? = nil,
                     onAnswer: ((String) -> Void)? = nil) {
        isRunning = true
        let message = Message(role: .user, text: shown)
        messages.append(message)
        let attached = given ?? area
        if given == nil { area = nil }
        Task {
            var shot = attached
            if shot == nil && withScreen {
                do {
                    shot = try await ScreenCapture.capture()
                } catch {
                    isRunning = false
                    return fail(error.localizedDescription)
                }
            }
            await run(prompt, shot: shot, after: message.id, onAnswer: onAnswer)
        }
    }

    func stop() {
        guard let process else { return }
        stopped = true
        process.terminate()
    }

    func newChat() {
        stopWatching()
        stop()
        chat += 1
        messages = []
        sessionID = nil
        draft = ""
        try? FileManager.default.removeItem(at: Self.savedFile)
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // MARK: Watch mode

    func toggleWatching() {
        if isWatching { stopWatching() } else { startWatching() }
    }

    /// Shows Claude the window you're working in now, then again each time it changes
    /// and settles (switching to another app counts). Only while the Ask window is
    /// open: hiding it pauses watching.
    private func startWatching() {
        isWatching = true
        screenWatch = ScreenWatch()
        watcher = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if isPanelVisible() && !isRunning {
                    await look(first: first)
                    first = false
                }
                try? await Task.sleep(for: .seconds(first ? 0.5 : 3))
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        isWatching = false
    }

    private func look(first: Bool) async {
        let shot: ScreenCapture.Shot
        do {
            shot = try await ScreenCapture.capture(.frontWindow)
        } catch {
            stopWatching()
            return fail(error.localizedDescription)
        }
        guard isWatching, !isRunning, screenWatch.needsCheck(shot.thumbnail) else { return }
        let lines = await shot.lines()
        guard isWatching, !isRunning, screenWatch.isNew(shot.thumbnail, lines: lines) else { return }
        screenWatch.sent(shot.thumbnail, lines: lines)
        isRunning = true
        let place = shot.appName.map { " in \($0)" } ?? ""
        let marker = Message(role: .watch, text: (first ? "Watching" : "New screen") + place, withScreen: true)
        messages.append(marker)
        var prompt = first ? ClaudeCLI.watchStartPrompt : ClaudeCLI.watchUpdatePrompt
        if let app = shot.appName { prompt += " (This screenshot is just my \(app) window.)" }
        await run(prompt, shot: shot, after: marker.id, quietIfNothingNew: !first)
    }

    // MARK: Error helper

    /// Explains an error the error helper spotted, from a careful read of the window's
    /// text plus the screenshot.
    func explainError(_ found: ErrorWatcher.Found) {
        guard !isRunning else { return fail("Still answering; try again when it\u{2019}s done.") }
        Task {
            let lines = await TextRecognition.lines(in: found.shot.image, fast: false)
            let errors = ErrorScan.errorLines(lines)
            let excerpt = errors.isEmpty ? lines.suffix(30).joined(separator: "\n") : ErrorScan.excerpt(lines, errors: errors)
            let place = found.app.map { " in \($0)" } ?? ""
            ask(ErrorScan.explainPrompt(excerpt, app: found.app),
                showing: "Explain the error\(place): \u{201C}\(ClaudeCLI.selectionPreview(found.preview, length: 100))\u{201D}",
                withScreen: false, shot: found.shot)
        }
    }

    // MARK: Due dates to Daybook

    /// Reads the due dates on the window you're using (or an attached area) and lists
    /// them to check over before they go to Daybook.
    func findDeadlines() {
        guard !isRunning else { return fail("Still answering; try again when it\u{2019}s done.") }
        isRunning = true
        let attached = area
        area = nil
        let chat = self.chat
        Task {
            stopped = false
            defer { if self.chat == chat { isRunning = false; process = nil; save() } }
            let shot: ScreenCapture.Shot
            do {
                if let attached { shot = attached } else { shot = try await ScreenCapture.capture(.frontWindow) }
            } catch {
                return fail(error.localizedDescription)
            }
            let place = attached != nil ? " in the selected area" : shot.appName.map { " in \($0)" } ?? ""
            messages.append(Message(role: .user, text: "Find due dates\(place)", withScreen: true))
            let result = await complete(Deadlines.prompt(), shot: shot)
            guard self.chat == chat else { return }
            switch result {
            case .failure(let failure):
                if !stopped { fail(failure.message) }
            case .success(let reply):
                guard let items = Deadlines.parse(reply) else {
                    return fail("Couldn\u{2019}t read the due dates from Claude\u{2019}s reply. Try again, or ask about them instead.")
                }
                let text = items.isEmpty ? "No due dates on this screen. Scroll to them, or pick an area with \u{2303}\u{2325}A, and try again."
                    : "\(items.count) due date\(items.count == 1 ? "" : "s") found. Untick any you don\u{2019}t want, then add them."
                messages.append(Message(role: items.isEmpty ? .claude : .deadlines, text: text, deadlines: items.isEmpty ? nil : items))
            }
        }
    }

    /// Sends the chosen due dates of a list to Daybook as tasks.
    func addToDaybook(_ messageID: UUID, keeping chosen: [Deadlines.Item]) {
        for item in chosen {
            guard let text = Deadlines.quickAddText(item) else { continue }
            var link = URLComponents()
            link.scheme = "daybook"
            link.host = "add-task"
            link.queryItems = [URLQueryItem(name: "text", value: text)]
            guard let url = link.url else { continue }
            // In the background, without bringing Daybook forward.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                guard let error else { return }
                Task { @MainActor in self.fail("Couldn\u{2019}t reach Daybook: \(error.localizedDescription)") }
            }
        }
        update(messageID) { $0.added = chosen.count }
        save()
    }

    // MARK: Study notes

    var notesFile: URL { notes.file(for: .now) }

    /// Claude, with the whole conversation in mind, writes a review sheet; it's shown
    /// here and saved at the end of today's notes.
    func makeStudyGuide() {
        guard !messages.isEmpty else { return fail("Ask about some problems first; the study guide is made from this conversation.") }
        guard !isRunning else { return fail("Still answering; try again when it\u{2019}s done.") }
        ask(StudyNotes.studyGuidePrompt, showing: "Make a study guide", withScreen: false) { [weak self] guide in
            guard let self else { return }
            if writeNote(StudyNotes.studyGuide(guide, at: .now)) {
                messages.append(Message(role: .note, text: "Saved to \(notesFile.lastPathComponent) in \(notes.folder.lastPathComponent)",
                                        symbol: "note.text"))
            }
        }
    }

    func openNotes() {
        if FileManager.default.fileExists(atPath: notesFile.path) {
            NSWorkspace.shared.open(notesFile)
        } else if FileManager.default.fileExists(atPath: notes.folder.path) {
            NSWorkspace.shared.open(notes.folder)
        } else {
            fail("No notes yet. Turn on Take Notes and they\u{2019}ll start with the next answer.")
        }
    }

    @discardableResult
    private func writeNote(_ markdown: String) -> Bool {
        do {
            try notes.append(markdown)
            return true
        } catch {
            fail("Couldn\u{2019}t save to your notes: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Memory

    private struct Saved: Codable {
        var sessionID: String?
        var messages: [Message]
        var lastActivity: Date
    }

    private static var savedFile: URL { ConfigFile.folder.appending(path: "Ask/conversation.json") }

    /// How long a conversation is kept with nothing asked. 3 hours unless set with
    /// `defaults write com.masonkimball.Hop askMemoryHours -float 8`.
    private var memoryWindow: TimeInterval {
        let hours = UserDefaults.standard.double(forKey: "askMemoryHours")
        return (hours > 0 ? hours : 3) * 3600
    }

    private var isFresh: Bool { Date.now.timeIntervalSince(lastActivity) < memoryWindow }

    private func save() {
        lastActivity = .now
        let saved = Saved(sessionID: sessionID, messages: messages, lastActivity: lastActivity)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.savedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.savedFile, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.savedFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        lastActivity = saved.lastActivity
        guard isFresh else { return newChat() }
        sessionID = saved.sessionID
        messages = saved.messages
    }

    // MARK: Running the CLI

    /// One turn. `prompt` goes to Claude with `shot`; the reply goes after the message
    /// `after`, which gets marked as having sent a screenshot. With `quietIfNothingNew`,
    /// a `ClaudeCLI.nothingNew` reply removes the turn instead of showing it.
    private func run(_ prompt: String, shot: ScreenCapture.Shot?, after: UUID, quietIfNothingNew: Bool = false,
                     onAnswer: ((String) -> Void)? = nil) async {
        let chat = self.chat
        stopped = false
        defer {
            if self.chat == chat { isRunning = false; process = nil; save() }
        }
        if shot != nil { update(after) { $0.withScreen = true } }

        let launched: Launched
        do {
            launched = try launch(prompt, shot: shot,
                                  arguments: ClaudeCLI.arguments(resuming: sessionID, model: UserDefaults.standard.string(forKey: "claudeModel"),
                                                                 tutor: isTutoring))
        } catch {
            return fail(error.message)
        }
        let (process, output, errorLog) = (launched.process, launched.output, launched.errorLog)
        self.process = process

        // The reply is added once there's something to show. A watch reply waits until
        // it can't be "nothing new", so that one never flashes up.
        var answer = ""
        var reply: UUID?
        var streamed = false
        var finished = false
        func show(_ text: String) {
            answer = text
            guard self.chat == chat else { return }
            if reply == nil, !answer.isEmpty, !(quietIfNothingNew && ClaudeCLI.mightBeNothingNew(answer)) {
                let message = Message(role: .claude, text: "")
                reply = message.id
                messages.append(message)
            }
            if let reply { update(reply) { $0.text = answer } }
        }

        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard self.chat == chat else { continue }
                switch ClaudeCLI.parse(line: line) {
                case .started(let id):
                    sessionID = id
                case .textDelta(let text):
                    streamed = true
                    show(answer + text)
                case .message(let text):
                    if !streamed { show(answer + text) }
                case .finished(let id, let result, let isError):
                    finished = true
                    if let id { sessionID = id }
                    if isError {
                        if let reply { messages.removeAll { $0.id == reply } }
                        return fail(ClaudeCLI.explain(result))
                    }
                    if answer.isEmpty { show(result) }
                    if quietIfNothingNew && ClaudeCLI.mightBeNothingNew(answer) {
                        messages.removeAll { $0.id == after || $0.id == reply }
                    } else if let onAnswer {
                        onAnswer(answer)
                    } else if isTakingNotes, !answer.isEmpty {
                        let question = messages.first { $0.id == after }?.text ?? "Question"
                        writeNote(StudyNotes.entry(question: question, answer: answer, at: .now))
                    }
                case nil:
                    break
                }
            }
        } catch {
            // The pipe closing early is reported below.
        }

        guard !finished, self.chat == chat else { return }
        if answer.isEmpty, let reply { messages.removeAll { $0.id == reply } }
        guard !stopped else { return }
        // Output closes just before the process exits; its error log is complete after.
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        let log = (try? String(contentsOf: errorLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fail(ClaudeCLI.explain(log.isEmpty ? "Claude Code stopped without answering." : log))
    }

    private struct Launched {
        let process: Process
        let output: Pipe
        let errorLog: URL
    }

    private struct LaunchFailure: Error {
        let message: String
    }

    /// Starts the CLI with `prompt` (and the screenshot) as its one message.
    private func launch(_ prompt: String, shot: ScreenCapture.Shot?, arguments: [String]) throws(LaunchFailure) -> Launched {
        guard let claude = ClaudeCLI.locate(override: UserDefaults.standard.string(forKey: "claudePath")) else {
            throw LaunchFailure(message: "Couldn\u{2019}t find the `claude` command. Install Claude Code (`brew install --cask claude-code`), or point Hop at it with `defaults write com.masonkimball.Hop claudePath /path/to/claude`.")
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        // Its own folder, so sessions it saves don't mix with real projects.
        let folder = ConfigFile.folder.appending(path: "Ask")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = folder
        // A Claude Code session's variables (if Hop was started from one) would make
        // the CLI act as a child of it instead of using its own sign-in.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let input = Pipe(), output = Pipe()
        let errorLog = folder.appending(path: "last-error.log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        process.standardInput = input
        process.standardOutput = output
        // A file, not a pipe: nobody reads stderr while the answer streams, and a
        // full pipe would stall the CLI.
        process.standardError = try? FileHandle(forWritingTo: errorLog)
        do {
            try process.run()
        } catch {
            throw LaunchFailure(message: "Couldn\u{2019}t start \(claude.path): \(error.localizedDescription)")
        }
        // Stream-json input has to come through a pipe; the CLI drops it from a file.
        try? input.fileHandleForWriting.write(contentsOf: ClaudeCLI.inputLine(question: prompt, screenshot: shot?.jpeg))
        try? input.fileHandleForWriting.close()
        return Launched(process: process, output: output, errorLog: errorLog)
    }

    /// A one-off request outside the conversation: Claude's whole reply, or what went wrong.
    private func complete(_ prompt: String, shot: ScreenCapture.Shot?) async -> Result<String, LaunchFailure> {
        let launched: Launched
        do {
            launched = try launch(prompt, shot: shot,
                                  arguments: ClaudeCLI.arguments(resuming: nil, model: UserDefaults.standard.string(forKey: "claudeModel"),
                                                                 persist: false))
        } catch {
            return .failure(error)
        }
        self.process = launched.process
        var answer = ""
        do {
            for try await line in launched.output.fileHandleForReading.bytes.lines {
                switch ClaudeCLI.parse(line: line) {
                case .finished(_, let result, let isError):
                    return isError ? .failure(LaunchFailure(message: ClaudeCLI.explain(result))) : .success(answer.isEmpty ? result : answer)
                case .message(let text):
                    answer += text
                default:
                    break
                }
            }
        } catch {}
        if stopped { return .failure(LaunchFailure(message: "Stopped.")) }
        while launched.process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        let log = (try? String(contentsOf: launched.errorLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(LaunchFailure(message: ClaudeCLI.explain(log.isEmpty ? "Claude Code stopped without answering." : log)))
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }

    private func fail(_ text: String) {
        messages.append(Message(role: .error, text: text))
    }
}
