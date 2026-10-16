import Foundation
import HopCore
import Synchronization

/// One running `claude` CLI in stream-json mode. Ask Claude keeps one open for the
/// conversation, started when the window opens, so a question goes to a process
/// that's already up: the first words arrive in under a second instead of two or
/// more. One-off requests (reading due dates) start their own and let it exit.
@MainActor
final class ClaudeProcess {
    struct Failure: Error {
        let message: String
    }

    /// What it was started with, to tell when a setting change needs a new one.
    let model: String?
    let tutor: Bool

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorLog: URL
    /// Gets each event while a turn is running.
    private var deliver: ((ClaudeCLI.Event) -> Void)?
    private var ended: (() -> Void)?
    private var outputClosed = false

    var isAlive: Bool { process.isRunning && !outputClosed }

    /// `executable` is the CLI to run (nil: found the usual way); `folder` is where it
    /// runs and writes its error log.
    init(arguments: [String], model: String?, tutor: Bool, errorLogName: String,
         executable: URL? = nil, folder: URL = ConfigFile.folder.appending(path: "Ask")) throws(Failure) {
        self.model = model
        self.tutor = tutor
        guard let claude = executable ?? ClaudeCLI.locate(override: UserDefaults.standard.string(forKey: "claudePath")) else {
            throw Failure(message: "Couldn\u{2019}t find the `claude` command. Install Claude Code (`brew install --cask claude-code`), or point Hop at it with `defaults write com.masonkimball.Hop claudePath /path/to/claude`.")
        }
        process.executableURL = claude
        process.arguments = arguments
        // Its own folder, so sessions it saves don't mix with real projects.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = folder
        // A Claude Code session's variables (if Hop was started from one) would make
        // the CLI act as a child of it instead of using its own sign-in.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        errorLog = folder.appending(path: errorLogName)
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        process.standardInput = input
        process.standardOutput = output
        // A file, not a pipe: nobody reads stderr while answers stream, and a full
        // pipe would stall the CLI.
        process.standardError = try? FileHandle(forWritingTo: errorLog)
        do {
            try process.run()
        } catch {
            throw Failure(message: "Couldn\u{2019}t start \(claude.path): \(error.localizedDescription)")
        }

        // Read with a readability handler, not FileHandle.bytes: a `for await` over the
        // bytes of a pipe that's gone quiet (the warm CLI between questions) held up
        // other pipes' reads and even timers until that process exited. The handler
        // runs on a background queue only when data arrives, and hands each line to
        // the main queue in order.
        // One handle's callbacks never overlap; the lock is for the compiler's sake.
        let buffer = Mutex(LineBuffer())
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            let lines: [String]
            let closed = chunk.isEmpty
            if closed {
                handle.readabilityHandler = nil
                lines = buffer.withLock { $0.finish() }.map { [$0] } ?? []
            } else {
                lines = buffer.withLock { $0.append(chunk) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in lines {
                        if let event = ClaudeCLI.parse(line: line) { self?.deliver?(event) }
                    }
                    if closed {
                        self?.outputClosed = true
                        self?.ended?()
                    }
                }
            }
        }
    }

    /// Sends one message (the screenshot, then the text) and streams back what Claude
    /// does with it. The stream ends after `.finished`, or early if the CLI exits.
    func turn(_ prompt: String, screenshot: Data?) -> AsyncStream<ClaudeCLI.Event> {
        AsyncStream { continuation in
            // Hop sends one turn at a time; if a second ever came while one was still
            // going, end the first one's stream rather than leave it waiting forever.
            ended?()
            deliver = { event in
                continuation.yield(event)
                if case .finished = event { continuation.finish() }
            }
            ended = { continuation.finish() }
            guard !outputClosed else { return continuation.finish() }
            // Stream-json input has to come through a pipe; the CLI drops it from a file.
            // Hop ignores SIGPIPE (main.swift), so a CLI that already exited makes this
            // throw instead of killing Hop.
            do {
                try input.fileHandleForWriting.write(contentsOf: ClaudeCLI.inputLine(question: prompt, screenshot: screenshot))
            } catch {
                continuation.finish()
            }
        }
    }

    /// For one-off requests: no more messages, so the CLI exits after answering.
    func finishInput() {
        try? input.fileHandleForWriting.close()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// What the CLI printed before it stopped, once it has. Waits up to 2 seconds for it
    /// to exit; a fixed number of tries, since in a cancelled task the sleep returns
    /// straight away and an open-ended loop would spin.
    func errorText() async -> String {
        for _ in 0..<100 where process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        terminate()
        let log = (try? String(contentsOf: errorLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ClaudeCLI.explain(log.isEmpty ? "Claude Code stopped without answering." : log)
    }
}
