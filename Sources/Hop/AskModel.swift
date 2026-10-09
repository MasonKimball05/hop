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
    /// Listening to a spoken question, which fills in the draft as it's heard.
    private(set) var isListening = false
    @ObservationIgnored private let dictation = Dictation()
    @ObservationIgnored private var wantsToListen = false
    /// Add each answered question to today's study notes file.
    var isTakingNotes = UserDefaults.standard.bool(forKey: "askNotes") {
        didSet { UserDefaults.standard.set(isTakingNotes, forKey: "askNotes") }
    }
    /// Read fresh each time, so a folder changed in Settings applies right away.
    private var notes: StudyNotes { StudyNotes() }
    /// An area of the screen picked with Ask About Area, sent with the next question
    /// in place of a screenshot.
    private(set) var area: ScreenCapture.Shot?
    /// What the attached image is called: a dropped file's name, or nil for a picked area.
    private(set) var areaName: String?

    /// A dropped document's text, sent with the next question.
    struct AttachedText {
        let name: String
        let text: String
    }

    private(set) var attachedText: AttachedText?
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
    /// The conversation's CLI, kept running between questions.
    @ObservationIgnored private var session: ClaudeProcess?
    /// A one-off request's CLI (reading due dates), while it runs.
    @ObservationIgnored private var oneOff: ClaudeProcess?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var lastActivity = Date.now
    /// Bumped by New Chat, so a turn still finishing can't write into the new one.
    @ObservationIgnored private var chat = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var screenWatch = ScreenWatch()
    @ObservationIgnored private var lastNewScreen = Date.now

    /// Set by the app delegate.
    var close: () -> Void = {}
    var isPanelVisible: () -> Bool = { false }

    init() { restore() }

    func didShow() {
        if !isRunning && !isFresh { newChat() }
        focusCount += 1
        warmUp()
    }

    func send(_ text: String? = nil) {
        var question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // With something attached, Return on its own asks about it.
        if question.isEmpty && area != nil { question = "What's this? Help me with it." }
        if question.isEmpty && attachedText != nil { question = "Summarize this and help me with it." }
        guard !question.isEmpty, !isRunning else { return }
        draft = ""
        if let file = attachedText {
            // The file is the context, so no screenshot with it.
            attachedText = nil
            return ask(ClaudeCLI.attachmentPrompt(name: file.name, text: file.text, question: question),
                       showing: question + "\n\u{1F4CE} " + file.name, withScreen: false)
        }
        ask(question, showing: question, withScreen: includeScreen || isWatching)
    }

    /// Attaches an image (an area of the screen, or a dropped picture) to the next question.
    func attach(area image: CGImage, name: String? = nil) {
        do {
            area = try ScreenCapture.shot(area: image)
            areaName = name
            attachedText = nil
            focusCount += 1
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Attaches a file dropped on the window: its text, or a picture of it.
    func attach(file url: URL) {
        do {
            switch try FileAttachment.read(url) {
            case .image(let image):
                attach(area: image, name: url.lastPathComponent)
            case .text(let text):
                attachedText = AttachedText(name: url.lastPathComponent, text: text)
                area = nil
                focusCount += 1
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func removeArea() {
        area = nil
        attachedText = nil
    }

    /// Explains text selected in another app. No screenshot: the text is the question.
    func explain(_ selection: String?, from app: String?) {
        guard let selection else {
            return fail("Nothing selected. Select some text in any app, then press \(Shortcuts.display(.explain)).")
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
        guard isRunning else { return }
        stopped = true
        // A turn can't be cut short inside the CLI, so it goes; the next question starts
        // a new one that resumes the same conversation.
        session?.terminate()
        session = nil
        oneOff?.terminate()
    }

    func newChat() {
        stopWatching()
        stop()
        chat += 1
        session?.terminate()
        session = nil
        messages = []
        sessionID = nil
        draft = ""
        try? FileManager.default.removeItem(at: Self.savedFile)
        if isPanelVisible() { warmUp() }
    }

    /// Copies an answer as plain text; `markdown` keeps its formatting, for notes apps.
    func copy(_ message: Message, markdown: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown ? message.text : Markdown.plainText(message.text), forType: .string)
    }

    /// Set by the app delegate: pastes into the app you're using.
    var pasteIntoApp: (String) -> Void = { _ in }

    /// Pastes an answer, as plain text, into the app you're using.
    func paste(_ message: Message) {
        pasteIntoApp(Markdown.plainText(message.text))
    }

    /// ⌃⌥V: the latest answer, into the app you're using.
    func pasteLatestAnswer() {
        guard let answer = messages.last(where: { $0.role == .claude && !$0.text.isEmpty }) else {
            return Toast.show("No answer to paste yet", symbol: "text.bubble")
        }
        paste(answer)
    }

    // MARK: Voice

    func toggleListening() {
        if isListening || wantsToListen { stopListening(send: true) } else { startListening() }
    }

    /// Listens for a spoken question; what's heard goes in the draft, after anything
    /// already typed.
    func startListening() {
        guard !wantsToListen else { return }
        wantsToListen = true
        let typed = draft.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await dictation.start { heard in
                    guard self.isListening else { return }
                    self.draft = typed.isEmpty ? heard : typed + " " + heard
                }
            } catch {
                wantsToListen = false
                return fail(error.localizedDescription)
            }
            isListening = true
            // Let go before the microphone was even ready.
            if !wantsToListen { stopListening(send: true) }
        }
    }

    /// Stops listening and, with `send`, asks what was heard once the last words are in.
    func stopListening(send: Bool) {
        wantsToListen = false
        guard isListening else { return }
        dictation.stop()
        Task {
            // The recognizer delivers its final words just after the audio stops.
            try? await Task.sleep(for: .milliseconds(400))
            isListening = false
            if send { self.send() }
        }
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
        lastNewScreen = .now
        watcher = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if Date.now.timeIntervalSince(lastNewScreen) > watchIdleLimit {
                    stopWatching()
                    let minutes = Int(watchIdleLimit / 60)
                    messages.append(Message(role: .note, text: "Stopped watching after \(minutes) minutes with nothing new", symbol: "eye.slash"))
                    return
                }
                if isPanelVisible() && !isRunning {
                    await look(first: first)
                    first = false
                }
                try? await Task.sleep(for: .seconds(first ? 0.5 : 3))
            }
        }
    }

    /// Watching stops by itself after this long without a new screen, so a forgotten
    /// session doesn't keep using Claude. 20 minutes unless set with
    /// `defaults write com.masonkimball.Hop watchIdleMinutes -int 45`.
    private var watchIdleLimit: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: "watchIdleMinutes")
        return Double(minutes > 0 ? minutes : 20) * 60
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
        lastNewScreen = .now
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
            defer { if self.chat == chat { isRunning = false; oneOff = nil; save() } }
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
                let already = items.filter(wasAdded).count
                let found = "\(items.count) due date\(items.count == 1 ? "" : "s") found"
                let text = items.isEmpty ? "No due dates on this screen. Scroll to them, or pick an area with \(Shortcuts.display(.askArea)), and try again."
                    : already == items.count ? "\(found), all already in Daybook."
                    : already > 0 ? "\(found); \(already) already in Daybook, so those are unticked. Untick any others you don\u{2019}t want, then add them."
                    : "\(found). Untick any you don\u{2019}t want, then add them."
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
        addedDeadlines.formUnion(chosen.map(Deadlines.key))
        if let data = try? JSONEncoder().encode(addedDeadlines.sorted()) {
            try? data.write(to: Self.addedDeadlinesFile, options: .atomic)
        }
    }

    /// Due dates already sent to Daybook from Hop, so reading the same syllabus again
    /// doesn't add them twice.
    @ObservationIgnored private lazy var addedDeadlines: Set<String> = {
        guard let data = try? Data(contentsOf: Self.addedDeadlinesFile),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }()

    private static var addedDeadlinesFile: URL { ConfigFile.folder.appending(path: "Ask/added-deadlines.json") }

    func wasAdded(_ item: Deadlines.Item) -> Bool { addedDeadlines.contains(Deadlines.key(item)) }

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

    private var model: String? { UserDefaults.standard.string(forKey: "claudeModel") }

    /// The conversation's CLI: the running one, or a new one that resumes the
    /// conversation when there's none yet or tutor mode or the model changed.
    private func conversationProcess() throws(ClaudeProcess.Failure) -> ClaudeProcess {
        if let session, session.isAlive, session.model == model, session.tutor == isTutoring { return session }
        session?.terminate()
        let started = try ClaudeProcess(arguments: ClaudeCLI.arguments(resuming: sessionID, model: model, tutor: isTutoring),
                                        model: model, tutor: isTutoring, errorLogName: "last-error.log")
        session = started
        return started
    }

    /// Starts the CLI before the question comes, so it's ready when it does. Starting
    /// it doesn't use any Claude usage; only messages do.
    private func warmUp() {
        guard !isRunning else { return }
        _ = try? conversationProcess()
        resetIdleTimer()
    }

    /// A conversation left alone for 15 minutes gives its CLI back; the next question
    /// starts a new one that picks up where it left off.
    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15 * 60))
            guard let self, !Task.isCancelled, !isRunning else { return }
            session?.terminate()
            session = nil
        }
    }

    /// One turn. `prompt` goes to Claude with `shot`; the reply goes after the message
    /// `after`, which gets marked as having sent a screenshot. With `quietIfNothingNew`,
    /// a `ClaudeCLI.nothingNew` reply removes the turn instead of showing it.
    private func run(_ prompt: String, shot: ScreenCapture.Shot?, after: UUID, quietIfNothingNew: Bool = false,
                     onAnswer: ((String) -> Void)? = nil) async {
        let chat = self.chat
        stopped = false
        defer {
            if self.chat == chat { isRunning = false; save(); resetIdleTimer() }
        }
        if shot != nil { update(after) { $0.withScreen = true } }

        let claude: ClaudeProcess
        do {
            claude = try conversationProcess()
        } catch {
            return fail(error.message)
        }

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

        for await event in claude.turn(prompt, screenshot: shot?.jpeg) {
            guard self.chat == chat else { continue }
            switch event {
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
            }
        }

        guard !finished, self.chat == chat else { return }
        // The CLI exited partway: stopped, or something went wrong.
        if answer.isEmpty, let reply { messages.removeAll { $0.id == reply } }
        if session === claude { session = nil }
        guard !stopped else { return }
        fail(await claude.errorText())
    }

    /// A one-off request outside the conversation: Claude's whole reply, or what went wrong.
    private func complete(_ prompt: String, shot: ScreenCapture.Shot?) async -> Result<String, ClaudeProcess.Failure> {
        let claude: ClaudeProcess
        do {
            claude = try ClaudeProcess(arguments: ClaudeCLI.arguments(resuming: nil, model: model, persist: false),
                                       model: model, tutor: false, errorLogName: "one-off-error.log")
        } catch {
            return .failure(error)
        }
        oneOff = claude
        let events = claude.turn(prompt, screenshot: shot?.jpeg)
        claude.finishInput()
        var answer = ""
        for await event in events {
            switch event {
            case .finished(_, let result, let isError):
                return isError ? .failure(.init(message: ClaudeCLI.explain(result))) : .success(answer.isEmpty ? result : answer)
            case .message(let text):
                answer += text
            default:
                break
            }
        }
        if stopped { return .failure(.init(message: "Stopped.")) }
        return .failure(.init(message: await claude.errorText()))
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }

    private func fail(_ text: String) {
        messages.append(Message(role: .error, text: text))
    }
}
