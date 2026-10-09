import Foundation
import Testing
@testable import HopCore

@Suite struct ClaudeCLITests {
    @Test func findsTheFirstInstalledCLI() {
        let installed: Set<String> = ["/Users/me/.local/bin/claude", "/usr/local/bin/claude"]
        let found = ClaudeCLI.locate(home: "/Users/me", isExecutable: installed.contains)
        #expect(found?.path == "/usr/local/bin/claude")
        #expect(ClaudeCLI.locate(override: "/Users/me/.local/bin/claude", home: "/Users/me", isExecutable: installed.contains)?.path
                == "/Users/me/.local/bin/claude")
        #expect(ClaudeCLI.locate(home: "/Users/me", isExecutable: { _ in false }) == nil)
    }

    @Test func argumentsResumeAndPickTheModel() {
        let first = ClaudeCLI.arguments(resuming: nil, model: nil)
        #expect(!first.contains("--resume") && !first.contains("--model"))
        // Advice only: the empty tool list must be its own argument.
        #expect(first.firstIndex(of: "--tools").map { first[$0 + 1] } == "")
        // Auto-memory off, or "remember this" makes it stop to save a memory first.
        #expect(first.firstIndex(of: "--settings").map { first[$0 + 1].contains(#""autoMemoryEnabled":false"#) } == true)
        let next = ClaudeCLI.arguments(resuming: "abc", model: "sonnet")
        #expect(next.suffix(4) == ["--model", "sonnet", "--resume", "abc"])
        let prompt = { (args: [String]) in args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] } ?? "" }
        #expect(!prompt(first).contains(ClaudeCLI.tutorPrompt))
        #expect(prompt(ClaudeCLI.arguments(resuming: nil, model: nil, tutor: true)).contains(ClaudeCLI.tutorPrompt))
    }

    @Test func inputLinePutsTheScreenshotFirst() throws {
        let line = ClaudeCLI.inputLine(question: "what's this?", screenshot: Data([1, 2, 3]))
        #expect(line.last == 0x0A)
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let content = try #require((json["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == "AQID")
        #expect(content[1]["text"] as? String == "what's this?")

        let textOnly = try #require(try JSONSerialization.jsonObject(with: ClaudeCLI.inputLine(question: "hi", screenshot: nil)) as? [String: Any])
        #expect(((textOnly["message"] as? [String: Any])?["content"] as? [Any])?.count == 1)
    }

    @Test func parsesTheStream() {
        #expect(ClaudeCLI.parse(line: #"{"type":"system","subtype":"init","session_id":"s1","model":"x"}"#) == .started(sessionID: "s1"))
        #expect(ClaudeCLI.parse(line: #"{"type":"system","subtype":"hook_started","session_id":"s1"}"#) == nil)
        #expect(ClaudeCLI.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Click "}}}"#)
                == .textDelta("Click "))
        #expect(ClaudeCLI.parse(line: #"{"type":"stream_event","event":{"type":"message_start"}}"#) == nil)
        #expect(ClaudeCLI.parse(line: #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Click Save."}]}}"#)
                == .message("Click Save."))
        #expect(ClaudeCLI.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Click Save.","session_id":"s1"}"#)
                == .finished(sessionID: "s1", result: "Click Save.", isError: false))
        #expect(ClaudeCLI.parse(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate.","session_id":"s1"}"#)
                == .finished(sessionID: "s1", result: "Failed to authenticate.", isError: true))
        #expect(ClaudeCLI.parse(line: "not json") == nil)
    }

    @Test func explainsSignInErrors() {
        #expect(ClaudeCLI.explain("Failed to authenticate. API Error: 401").contains("/login"))
        #expect(ClaudeCLI.explain("Overloaded") == "Overloaded")
    }

    @Test func readsAskCommands() {
        #expect(ClaudeCLI.question(fromCommand: "ask how do I export this") == "how do I export this")
        #expect(ClaudeCLI.question(fromCommand: "? where's the undo") == "where's the undo")
        #expect(ClaudeCLI.question(fromCommand: "Ask  why is this red ") == "why is this red")
        #expect(ClaudeCLI.question(fromCommand: "ask ") == nil)
        #expect(ClaudeCLI.question(fromCommand: "asking") == nil)
        #expect(ClaudeCLI.question(fromCommand: "Asana") == nil)
    }
}

@Suite struct ScreenWatchTests {
    private let count = ScreenWatch.width * ScreenWatch.height
    private func screen(_ value: UInt8) -> [UInt8] { Array(repeating: value, count: count) }
    /// `screen(0)` with the first `pixels` pixels changed, like a line of text redrawn.
    private func edited(_ pixels: Int) -> [UInt8] { Array(repeating: 200, count: pixels) + Array(repeating: 0, count: count - pixels) }
    /// A page as Vision reads it, one string per line.
    private func page(_ lines: String...) -> Set<String> { ScreenWatch.lines(in: ["Calculus II: Homework 5", "Due Friday 11:59 PM"] + lines) }

    @Test func sendsTheFirstScreen() {
        var watch = ScreenWatch()
        let check = watch.needsCheck(screen(0))
        #expect(check && watch.isNew(screen(0), lines: []))
    }

    @Test func waitsForTheScreenToSettle() {
        var watch = ScreenWatch()
        watch.sent(screen(0), lines: [])
        let checks = [
            watch.needsCheck(screen(0)),    // nothing changed
            watch.needsCheck(screen(120)),  // scrolling
            watch.needsCheck(screen(120)),  // settled on something new
            watch.needsCheck(screen(120)),  // already checked
        ]
        #expect(checks == [false, false, true, false])
    }

    @Test func aFewChangedLinesAreWorthChecking() {
        var watch = ScreenWatch()
        watch.sent(screen(0), lines: [])
        // About 2% of the window: one question's text swapped for the next.
        let pixels = count / 50
        let checks = [watch.needsCheck(edited(pixels)), watch.needsCheck(edited(pixels))]
        #expect(checks == [false, true])
    }

    @Test func theNextQuestionIsNewButTypingAnAnswerIsNot() {
        var watch = ScreenWatch()
        let question3 = page("Question 3 of 10", "Find the derivative of f(x) = x^2 + 3x - 7", "Your answer:")
        watch.sent(screen(0), lines: question3)
        // Same page with different numbers: "5" is already on it, in "Homework 5".
        #expect(watch.isNew(edited(100), lines: page("Question 5 of 10", "Find the derivative of f(x) = x^3 + 5x - 2", "Your answer:")))
        // A question with no number, only its text replaced.
        #expect(watch.isNew(edited(100), lines: page("Question 3 of 10", "Evaluate the integral of 1/x from 1 to e", "Your answer:")))
        // Typing, then finishing, an answer.
        #expect(!watch.isNew(edited(100), lines: question3.union(ScreenWatch.lines(in: ["f'(x) = 2x"]))))
        watch.sent(screen(0), lines: question3.union(ScreenWatch.lines(in: ["f'(x) = 2x"])))
        #expect(!watch.isNew(edited(100), lines: question3.union(ScreenWatch.lines(in: ["f'(x) = 2x + 3"]))))
        #expect(!watch.isNew(edited(100), lines: question3.union(ScreenWatch.lines(in: ["f'(x) = 2x"]))))
    }

    @Test func aRedrawnScreenIsNewWithoutText() {
        var watch = ScreenWatch()
        watch.sent(screen(0), lines: [])
        #expect(watch.isNew(screen(200), lines: []))
    }

    @Test func normalizesLines() {
        #expect(ScreenWatch.lines(in: ["Question 4:", "  ", "f(x) = 2x"]) == ["question 4", "f x 2x"])
    }

    @Test func spotsTheNothingNewReply() {
        #expect(ClaudeCLI.mightBeNothingNew(""))
        #expect(ClaudeCLI.mightBeNothingNew("NOTHING_"))
        #expect(ClaudeCLI.mightBeNothingNew(" NOTHING_NEW\n"))
        #expect(!ClaudeCLI.mightBeNothingNew("Question 3 asks"))
        #expect(ClaudeCLI.watchUpdatePrompt.contains(ClaudeCLI.nothingNew))
    }
}

@Suite struct ExplainSelectionTests {
    @Test func promptNamesTheAppAndCarriesTheText() {
        let prompt = ClaudeCLI.explainPrompt("TypeError: x is undefined", app: "Safari")
        #expect(prompt.contains("selected in Safari") && prompt.hasSuffix("TypeError: x is undefined"))
        #expect(!ClaudeCLI.explainPrompt("hi", app: nil).contains(" in "))
    }

    @Test func longSelectionsAreCut() {
        let prompt = ClaudeCLI.explainPrompt(String(repeating: "a", count: ClaudeCLI.maxSelection + 500), app: nil)
        #expect(prompt.hasSuffix("[\u{2026}cut off]"))
        #expect(prompt.count < ClaudeCLI.maxSelection + 400)
    }

    @Test func previewIsOneShortLine() {
        #expect(ClaudeCLI.selectionPreview("  line one\n\n  line two ") == "line one line two")
        #expect(ClaudeCLI.selectionPreview(String(repeating: "x", count: 200), length: 10) == "xxxxxxxxxx\u{2026}")
    }
}

@Suite struct DeadlineTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func parsesTheReplyEvenWithAFence() throws {
        let reply = """
            Here they are:
            ```json
            [{"title": "Calc II: Problem Set 5", "due": "2026-10-24T23:59"},
             {"title": "Midterm 2", "due": "2026-11-03"},
             {"title": "Bad date", "due": "next week"}]
            ```
            """
        let items = try #require(Deadlines.parse(reply))
        #expect(items.map(\.title) == ["Calc II: Problem Set 5", "Midterm 2"])
        #expect(Deadlines.parse("[]") == [])
        #expect(Deadlines.parse("I couldn't find any.") == nil)
    }

    @Test func putsTheDateFirstForDaybook() {
        let timed = Deadlines.Item(title: "Read section 3.2", due: "2026-10-24T23:59")
        #expect(Deadlines.quickAddText(timed, timeZone: utc) == "Oct 24, 2026 11:59 PM Read section 3.2")
        let allDay = Deadlines.Item(title: "Midterm 2", due: "2026-11-03")
        #expect(Deadlines.quickAddText(allDay, timeZone: utc) == "Nov 3, 2026 Midterm 2")
        #expect(Deadlines.date(allDay, timeZone: utc)?.hasTime == false)
    }

    @Test func promptGivesTodaysDate() {
        let date = Date(timeIntervalSince1970: 1_791_547_200) // Oct 9, 2026, noon UTC
        #expect(Deadlines.prompt(now: date, timeZone: utc).contains("Friday, October 9, 2026"))
    }
}

@Suite struct StudyNotesTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_791_547_200) // Oct 9, 2026, noon UTC

    @Test func entryHasTheTimeAndFirstLineOfTheQuestion() {
        let entry = StudyNotes.entry(question: "Find the derivative\nof x^3 sin x", answer: "  Use the product rule.\n", at: date, timeZone: utc)
        #expect(entry == "## 12:00 PM \u{00B7} Find the derivative\n\nUse the product rule.\n\n")
    }

    @Test func appendsToOneFilePerDay() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = StudyNotes(folder: folder)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(notes.file(for: date, calendar: calendar).lastPathComponent == "2026-10-09.md")
        let file = try notes.append("first\n", at: date)
        try notes.append("second\n", at: date)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("# Study notes, ") && text.hasSuffix("first\nsecond\n"))
    }
}

@Suite struct ErrorScanTests {
    @Test func knowsDeveloperApps() {
        #expect(ErrorScan.isDeveloperApp("com.apple.Terminal"))
        #expect(ErrorScan.isDeveloperApp("com.jetbrains.goland"))
        #expect(!ErrorScan.isDeveloperApp("com.apple.Safari"))
        #expect(!ErrorScan.isDeveloperApp(nil))
    }

    @Test(arguments: [
        "Sources/Hop/AskModel.swift:211:46: error: 'async' call in an autoclosure",
        "error[E0308]: mismatched types",
        "TypeError: Cannot read properties of undefined (reading 'map')",
        "Traceback (most recent call last):",
        "ModuleNotFoundError: No module named 'requests'",
        "npm ERR! code ERESOLVE",
        "zsh: command not found: pyhton",
        "fatal: not a git repository (or any of the parent directories): .git",
        "** BUILD FAILED **",
        "java.lang.NullPointerException",
    ])
    func spotsErrors(line: String) {
        #expect(ErrorScan.errorLines(["$ make", line]) == [1])
    }

    @Test(arguments: [
        "Improved error handling in the parser",
        "0 errors, 2 warnings",
        "Build succeeded",
        "func handleError(_ e: Error) {",
    ])
    func ignoresOrdinaryText(line: String) {
        #expect(ErrorScan.errorLines([line]).isEmpty)
    }

    @Test func excerptKeepsContext() {
        let lines = (0..<30).map { "line \($0)" }
        let excerpt = ErrorScan.excerpt(lines, errors: [10], before: 2, after: 3)
        #expect(excerpt == "line 8\nline 9\nline 10\nline 11\nline 12\nline 13")
    }
}

@Suite struct DeadlineKeyTests {
    @Test func sameAssignmentMatchesWhateverTheTimeOrPunctuation() {
        let a = Deadlines.Item(title: "Calc II: Problem Set 5", due: "2026-10-24T23:59")
        let b = Deadlines.Item(title: "calc ii - problem set 5", due: "2026-10-24")
        let other = Deadlines.Item(title: "Calc II: Problem Set 6", due: "2026-10-24T23:59")
        #expect(Deadlines.key(a) == Deadlines.key(b))
        #expect(Deadlines.key(a) != Deadlines.key(other))
    }
}

@Suite struct MarkdownTests {
    @Test func splitsBlocks() {
        let text = """
            ## Product rule

            Use it when two functions multiply:

            1. Name **f** and **g**
            2. Differentiate each
               then combine
            - nested idea
              - deeper

            > Watch the sign.

            ```swift
            let x = 1
            ```
            ---
            Done.
            """
        let blocks = Markdown.blocks(text)
        #expect(blocks == [
            .heading(level: 2, text: "Product rule"),
            .paragraph("Use it when two functions multiply:"),
            .list([
                .init(marker: "1.", depth: 0, text: "Name **f** and **g**"),
                .init(marker: "2.", depth: 0, text: "Differentiate each\nthen combine"),
                .init(marker: "\u{2022}", depth: 0, text: "nested idea"),
                .init(marker: "\u{2022}", depth: 1, text: "deeper"),
            ]),
            .quote("Watch the sign."),
            .code(language: "swift", text: "let x = 1"),
            .rule,
            .paragraph("Done."),
        ])
    }

    @Test func unclosedCodeRunsToTheEndWhileStreaming() {
        #expect(Markdown.blocks("Try:\n```\nmake test") == [.paragraph("Try:"), .code(language: nil, text: "make test")])
    }

    @Test func displayMathBecomesUnicode() {
        #expect(Markdown.blocks("$$\\int x^{2}\\,dx = \\frac{x^3}{3} + C$$") == [.math("∫ x² dx = x³⁄3 + C")])
        #expect(Markdown.blocks("\\[\n\\sqrt{a^2+b^2}\n\\]") == [.math("√(a²+b²)")])
    }

    @Test(arguments: [
        ("\\frac{1}{x}", "1⁄x"),
        ("\\frac{d}{dx}\\left(x^3 \\sin x\\right)", "d⁄dx(x³ sin x)"),
        ("e^{x^2}", "e^(x^2)"),
        ("x_1 + x_{10}", "x₁ + x₁₀"),
        ("\\alpha \\leq \\pi \\cdot r^2", "α ≤ π · r²"),
        ("\\lim_{x \\to 0} \\frac{\\sin x}{x}", "lim_(x → 0) (sin x)⁄x"),
        ("\\text{area} = \\pi r^2", "area = π r²"),
    ])
    func latexToUnicode(latex: String, expected: String) {
        #expect(Markdown.unicodeMath(latex) == expected)
    }

    @Test func inlineMathButNotMoney() {
        #expect(Markdown.inlineMath("so $f'(x) = 3x^2$ here") == "so f'(x) = 3x² here")
        #expect(Markdown.inlineMath("costs $5 and $10") == "costs $5 and $10")
        #expect(Markdown.inlineMath("\\(\\theta = 90^\\circ\\)") == "θ = 90°")
    }
}

@Suite struct AttachmentTests {
    @Test func fileTextGoesBeforeTheQuestion() {
        let prompt = ClaudeCLI.attachmentPrompt(name: "notes.txt", text: "  line one\n", question: "Summarize this")
        #expect(prompt == "Attached file \"notes.txt\":\n\n```\nline one\n```\n\nSummarize this")
    }

    @Test func longFilesAreCut() {
        let prompt = ClaudeCLI.attachmentPrompt(name: "a", text: String(repeating: "x", count: ClaudeCLI.maxAttachment + 10), question: "q")
        #expect(prompt.contains("cut off") && prompt.count < ClaudeCLI.maxAttachment + 200)
    }
}

@Suite struct PlainTextTests {
    @Test func dropsMarkdownButKeepsStructure() {
        let answer = "## Steps\n\n1. Use the **product rule**\n2. Simplify `f'(x)`\n   - check $x^2$\n\n$$\\frac{1}{2}$$"
        #expect(Markdown.plainText(answer) == "Steps\n\n1. Use the product rule\n2. Simplify f'(x)\n  \u{2022} check x²\n\n1⁄2")
    }
}

@Suite struct ShortcutTests {
    private func scratch() -> UserDefaults {
        let name = "hop-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchWhatHopHasAlwaysUsed() {
        #expect(ShortcutAction.launcher.defaultShortcut.display == "\u{2325}Space")
        #expect(ShortcutAction.ask.defaultShortcut.display == "\u{2325}\u{21E7}Space")
        #expect(ShortcutAction.explain.defaultShortcut.display == "\u{2303}\u{2325}E")
        // Every default is different.
        #expect(Set(ShortcutAction.allCases.map(\.defaultShortcut)).count == ShortcutAction.allCases.count)
    }

    @Test func savesOnlyChangesAndCanTurnOneOff() {
        let defaults = scratch()
        var shortcuts = Shortcuts.load(from: defaults)
        #expect(shortcuts[.ask] == .some(ShortcutAction.ask.defaultShortcut))
        shortcuts[.ask] = .some(Shortcut(keyCode: 0, modifiers: Shortcut.command | Shortcut.shift, key: "A"))
        shortcuts[.copyText] = .some(nil)
        Shortcuts.save(shortcuts, to: defaults)
        let loaded = Shortcuts.load(from: defaults)
        #expect(loaded[.ask]??.display == "\u{21E7}\u{2318}A")
        #expect(loaded[.copyText] == .some(nil))
        #expect(loaded[.launcher] == .some(ShortcutAction.launcher.defaultShortcut))
        #expect(Shortcuts.display(.copyText, from: defaults) == "no shortcut")
        // Back to defaults clears the stored value entirely.
        Shortcuts.save(Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, .some($0.defaultShortcut)) }), to: defaults)
        #expect(defaults.data(forKey: Shortcuts.defaultsKey) == nil)
    }
}

@Suite struct FileSearchTests {
    @Test func readsTheCommand() {
        #expect(FileSearch.query(fromCommand: "f calc syllabus") == "calc syllabus")
        #expect(FileSearch.query(fromCommand: "find  resume ") == "resume")
        #expect(FileSearch.query(fromCommand: "f x") == nil)        // too short to search
        #expect(FileSearch.query(fromCommand: "facetime") == nil)
    }

    @Test func patternsEscapeWildcards() {
        #expect(FileSearch.namePatterns("calc syl") == ["*calc*", "*syl*"])
        #expect(FileSearch.namePatterns("a*b?") == ["*a\\*b\\?*"])
    }

    @Test func ranksPrefixMatchesThenRecentAndSkipsNoise() {
        let old = Date(timeIntervalSince1970: 0), new = Date()
        let hits = [
            FileSearch.Hit(name: "Old Calc Notes.md", path: "/Users/me/Documents/Old Calc Notes.md", lastUsed: new),
            FileSearch.Hit(name: "Calc Syllabus.pdf", path: "/Users/me/Downloads/Calc Syllabus.pdf", lastUsed: old),
            FileSearch.Hit(name: "calc.js", path: "/Users/me/code/app/node_modules/calc/calc.js", lastUsed: new),
            FileSearch.Hit(name: "Calc HW 5.pdf", path: "/Users/me/Documents/Calc HW 5.pdf", lastUsed: new),
        ]
        #expect(FileSearch.rank(hits, query: "calc").map(\.name) == ["Calc HW 5.pdf", "Calc Syllabus.pdf", "Old Calc Notes.md"])
    }
}

@Suite struct GitHubStatusTests {
    @Test func readsAPullRequestAndItsChecks() throws {
        let json = #"{"number":3,"title":"v0.3","url":"https://github.com/me/hop/pull/3","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","state":"SUCCESS"}]}"#
        let pr = try #require(GitHubStatus.pullRequest(from: Data(json.utf8)))
        #expect(pr.number == 3 && pr.checks == .failing && pr.passed == 2 && pr.total == 3)
        let running = #"{"number":4,"title":"x","url":"u","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":""}]}"#
        #expect(GitHubStatus.pullRequest(from: Data(running.utf8))?.checks == .running)
        #expect(GitHubStatus.pullRequest(from: Data(#"{"number":5,"title":"x","url":"u","statusCheckRollup":[]}"#.utf8))?.checks == GitHubStatus.Outcome.none)
    }

    @Test func readsTheLatestRun() {
        let json = #"[{"workflowName":"CI","status":"completed","conclusion":"success","url":"https://github.com/me/hop/actions/runs/1","createdAt":"2026-10-09T21:03:00Z"}]"#
        let run = GitHubStatus.latestRun(from: Data(json.utf8))
        #expect(run?.workflow == "CI" && run?.outcome == .passing && run?.started != nil)
        #expect(GitHubStatus.latestRun(from: Data("[]".utf8)) == nil)
    }
}

@Suite struct RewriteTests {
    @Test func rewritesAskForOnlyTheResult() {
        #expect(ClaudeCLI.Rewrite.fixGrammar.prompt("teh cat").contains("Reply with only the result"))
        #expect(ClaudeCLI.Rewrite.fixGrammar.prompt("teh cat").hasSuffix("\n\nteh cat"))
        #expect(!ClaudeCLI.Rewrite.explain.prompt("x").contains("Reply with only"))
    }
}
