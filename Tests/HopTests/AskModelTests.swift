import AppKit
import Foundation
import Testing
@testable import Hop
@testable import HopCore

/// A stand-in for `claude -p --input-format stream-json --output-format stream-json`.
/// It answers "turn N: <the question>" (N counts questions to this process), and what
/// the question says changes what it does: "SLOW" or "watch mode" thinks for 30 seconds
/// (for testing Stop), "FAIL" answers with a sign-in error, and resuming a session whose
/// id starts with "missing" exits the way Claude Code does when it has cleaned one up.
private let fakeClaude = #"""
#!/bin/bash
resume=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--resume" ]] && resume="${args[i+1]}"; done
if [[ "$resume" == missing* ]]; then
  echo "No conversation found with session ID: $resume" >&2
  exit 1
fi
session="${resume:-fake-$$}"
trap 'kill $sleeper 2>/dev/null; exit 0' TERM
echo '{"type":"system","subtype":"init","session_id":"'"$session"'"}'
turn=0
while IFS= read -r line; do
  turn=$((turn + 1))
  text=$(printf '%s' "$line" | sed -E 's/.*"text":"(([^"\\]|\\.)*)".*/\1/')
  case "$text" in *SLOW*|*"watch mode"*) sleep 30 & sleeper=$!; wait $sleeper ;; esac
  if [[ "$text" == *FAIL* ]]; then
    echo '{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate. API Error: 401","session_id":"'"$session"'"}'
    continue
  fi
  reply="turn $turn: ${text:0:60}"
  reply=${reply//\\/}
  reply=${reply//\"/}
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'"$reply"'"}}}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"'"$reply"'","session_id":"'"$session"'"}'
done
"""#

/// An Ask Claude conversation in a temporary folder, talking to the stand-in CLI, with a
/// made-up screenshot in place of the screen.
@MainActor
private struct Harness {
    let folder: URL
    let fake: URL
    let model: AskModel

    /// `captureDelay` makes the made-up screenshot slow, to act during it.
    init(captureDelay: Duration = .zero) throws {
        // As in the app (main.swift): writing to a CLI that has exited must not end the run.
        signal(SIGPIPE, SIG_IGN)
        folder = FileManager.default.temporaryDirectory.appending(path: "hop-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fake = folder.appending(path: "fake-claude")
        try fakeClaude.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let shot = Self.shot()
        model = AskModel(setup: .init(folder: folder.appending(path: "Ask"), claude: fake, capture: { _ in
            try? await Task.sleep(for: captureDelay)
            return shot
        }, readText: { _, _ in
            // Instant, in place of Vision (whose first read can take half a minute).
            ["error: something broke"]
        }))
        model.isPanelVisible = { true }
    }

    static func shot() -> ScreenCapture.Shot {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ScreenCapture.Shot(jpeg: Data([0xFF]), thumbnail: Array(repeating: 0, count: ScreenWatch.width * ScreenWatch.height),
                                  appName: "Preview", image: context.makeImage()!)
    }

    var lastReply: String? { model.messages.last { $0.role == .claude }?.text }
    var errors: [String] { model.messages.filter { $0.role == .error }.map(\.text) }

    /// For failures: where the conversation and the stand-in CLI are.
    var state: String {
        "running: \(model.isRunning), watching: \(model.isWatching), CLI alive: \(fakeIsRunning), messages: \(model.messages.map { "\($0.role): \($0.text.prefix(40))" })"
    }

    /// Whether a copy of the stand-in CLI is still running.
    var fakeIsRunning: Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", fake.path]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    func cleanUp() {
        model.stopWatching()
        model.stop()
        model.newChat()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Waits (up to `seconds`) for `condition`; false if it never came true.
@MainActor
private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

@MainActor
@Suite struct AskModelTests {
    @Test func followUpsGoToTheSameRunningCLI() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.send("hello")
        #expect(await eventually { !ask.model.isRunning && ask.lastReply != nil })
        #expect(ask.lastReply == "turn 1: hello")
        ask.model.send("and again")
        #expect(await eventually { ask.lastReply == "turn 2: and again" })
        #expect(ask.errors.isEmpty)
    }

    @Test func stopEndsAnAnswerAndTheNextQuestionStillWorks() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.send("SLOW question")
        #expect(await eventually { ask.fakeIsRunning })
        try await Task.sleep(for: .milliseconds(300))
        #expect(ask.model.isRunning)

        ask.model.stop()
        #expect(await eventually(3) { !ask.model.isRunning })
        #expect(await eventually(3) { !ask.fakeIsRunning })
        #expect(ask.errors.isEmpty && ask.lastReply == nil)

        // A new CLI picks up the conversation.
        ask.model.send("after stopping")
        #expect(await eventually { ask.lastReply == "turn 1: after stopping" }, "\(ask.state)")
    }

    @Test func turningWatchingOffEndsTheAnswerToItsScreen() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.toggleWatching()
        // The first look sends the screen; the stand-in thinks about it for 30 seconds.
        #expect(await eventually { ask.model.isRunning && ask.model.messages.contains { $0.role == .watch } })

        ask.model.toggleWatching()
        #expect(!ask.model.isWatching)
        #expect(await eventually(3) { !ask.model.isRunning }, "\(ask.state)")
        #expect(await eventually(3) { !ask.fakeIsRunning })
        #expect(ask.errors.isEmpty)

        ask.model.send("still answering?")
        #expect(await eventually { ask.lastReply?.hasPrefix("turn 1: still answering?") == true })
    }

    @Test func newChatInTheMiddleOfAnAnswerDoesNotGetStuck() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.send("SLOW question")
        #expect(await eventually { ask.fakeIsRunning })
        ask.model.newChat()
        // Before the fix this stayed true and every later question was ignored.
        #expect(!ask.model.isRunning)
        ask.model.send("new topic")
        #expect(await eventually { ask.lastReply == "turn 1: new topic" })
        #expect(await eventually(3) { ask.model.messages.count == 2 })
    }

    @Test func stopBeforeTheAnswerStartsIsNotLost() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        // Stop straight away, while the screenshot is still being taken and no CLI is
        // running yet: before the fix, the turn started anyway.
        ask.model.send("SLOW question")
        ask.model.stop()
        #expect(await eventually(3) { !ask.model.isRunning })
        try await Task.sleep(for: .milliseconds(500))
        #expect(!ask.fakeIsRunning && ask.lastReply == nil && ask.errors.isEmpty)
        ask.model.send("next")
        #expect(await eventually { ask.lastReply == "turn 1: next" })
    }

    @Test func newChatDuringTheScreenshotDropsTheOldQuestion() async throws {
        let ask = try Harness(captureDelay: .milliseconds(600))
        defer { ask.cleanUp() }
        ask.model.send("old question")
        ask.model.newChat()
        ask.model.send("new question")
        // Only the new question reaches Claude, as the first and only turn.
        #expect(await eventually { ask.lastReply == "turn 1: new question" })
        try await Task.sleep(for: .milliseconds(800))
        #expect(ask.model.messages.map(\.text) == ["new question", "turn 1: new question"])
        #expect(!ask.model.isRunning && ask.errors.isEmpty)
    }

    @Test func explainErrorKeepsOtherQuestionsOutUntilItsDone() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        let found = ErrorWatcher.Found(app: "Terminal", shot: Harness.shot(), preview: "error: something broke")
        ask.model.explainError(found)
        // Typed while the error is still being read: ignored (Ask is busy), not run alongside.
        ask.model.send("unrelated")
        #expect(!ask.model.messages.contains { $0.text == "unrelated" })
        #expect(await eventually { ask.lastReply?.hasPrefix("turn 1: This error is showing in Terminal") == true })
        #expect(await eventually(3) { !ask.model.isRunning })
        // And the conversation carries on normally afterwards.
        ask.model.send("thanks")
        #expect(await eventually { ask.lastReply == "turn 2: thanks" })
    }

    @Test func signInErrorsSayHowToFixThem() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.send("FAIL please")
        #expect(await eventually { !ask.model.isRunning && !ask.errors.isEmpty })
        #expect(ask.errors.last?.contains("/login") == true)
    }

    @Test func newChatKeepsTheOldOneInTheHistory() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        ask.model.send("product rule")
        #expect(await eventually { ask.lastReply == "turn 1: product rule" })
        ask.model.newChat()
        #expect(ask.model.messages.isEmpty)
        ask.model.toggleHistory()
        #expect(ask.model.history.map(\.title) == ["product rule"])
        ask.model.openConversation(ask.model.history[0].id)
        #expect(ask.model.messages.map(\.role) == [.user, .claude])
        // Reopened, it resumes its session: the stand-in's count starts over in a new
        // process, but the conversation continues.
        ask.model.send("follow up")
        #expect(await eventually { ask.lastReply == "turn 1: follow up" },
                "messages: \(ask.model.messages.map { "\($0.role): \($0.text)" }), running: \(ask.model.isRunning)")
        #expect(ask.errors.isEmpty)
    }

    @Test func aCleanedUpSessionCarriesOnFromTheTranscript() async throws {
        let ask = try Harness()
        defer { ask.cleanUp() }
        // A past conversation whose Claude Code session no longer exists.
        let archive = ConversationArchive<AskModel.Message>(folder: ask.folder.appending(path: "Ask/History"))
        let past = ConversationArchive<AskModel.Message>.Conversation(
            id: UUID(), title: "Old question", started: .now, updated: .now, sessionID: "missing-session",
            messages: [AskModel.Message(role: .user, text: "Old question"), AskModel.Message(role: .claude, text: "Old answer")])
        try archive.save(past, text: "old")

        ask.model.toggleHistory()
        ask.model.openConversation(past.id)
        ask.model.send("new question")
        // The stand-in echoes the start of what it was sent: the handed-over transcript.
        #expect(await eventually { ask.lastReply?.hasPrefix("turn 1: We talked earlier") == true })
        #expect(ask.errors.isEmpty)
    }
}
