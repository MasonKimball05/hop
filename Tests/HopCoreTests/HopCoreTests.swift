import Foundation
import Testing
@testable import HopCore

@Suite struct FuzzyMatcherTests {
    @Test func matchesInOrderOnly() {
        #expect(FuzzyMatcher.score("term", in: "Terminal") != nil)
        #expect(FuzzyMatcher.score("mret", in: "Terminal") == nil)
        #expect(FuzzyMatcher.score("xyz", in: "Safari") == nil)
    }

    @Test func initialsBeatScatteredLetters() throws {
        let initials = try #require(FuzzyMatcher.score("vsc", in: "Visual Studio Code"))
        let scattered = try #require(FuzzyMatcher.score("vsc", in: "Vanessa's Cookbook"))
        #expect(initials > scattered)
    }

    @Test func prefixBeatsMiddle() throws {
        let prefix = try #require(FuzzyMatcher.score("mail", in: "Mail"))
        let middle = try #require(FuzzyMatcher.score("mail", in: "Gmail Helper"))
        #expect(prefix > middle)
    }

    @Test func camelCaseCountsAsWordStart() {
        #expect(FuzzyMatcher.initials(of: Array("FaceTime")) == "ft")
        #expect(FuzzyMatcher.initials(of: Array("Visual Studio Code")) == "vsc")
    }
}

@Suite struct RankingTests {
    let apps = ["Safari", "Shortcuts", "Slack", "System Settings"]

    @Test func usageLiftsAFavorite() {
        var usage = UsageCounts()
        let plain = Ranking.rank(apps, query: "s", name: { $0 }, key: { $0 }, usage: usage)
        for _ in 0..<5 { usage.record("Slack") }
        let ranked = Ranking.rank(apps, query: "s", name: { $0 }, key: { $0 }, usage: usage)
        #expect(ranked.first == "Slack")
        #expect(plain.first != "Slack" || plain == ranked)
    }

    @Test func usageDoesNotBeatAMuchBetterMatch() {
        var usage = UsageCounts()
        for _ in 0..<50 { usage.record("Shortcuts") }
        let ranked = Ranking.rank(apps, query: "system settings", name: { $0 }, key: { $0 }, usage: usage)
        #expect(ranked.first == "System Settings")
    }

    @Test func emptyQueryShowsMostUsedFirst() {
        var usage = UsageCounts()
        usage.record("Slack")
        let ranked = Ranking.rank(apps, query: "", name: { $0 }, key: { $0 }, usage: usage)
        #expect(ranked == ["Slack", "Safari", "Shortcuts", "System Settings"])
    }
}

@Suite struct CalculatorTests {
    @Test(arguments: [
        ("2+3*4", "14"),
        ("(2+3)*4", "20"),
        ("2^3^2", "512"),
        ("-3^2", "-9"),
        ("10/4", "2.5"),
        ("10 % 4", "2"),
        ("sqrt(16) + 1", "5"),
        ("1,000 * 3", "3000"),
        ("12 × 3 ÷ 4", "9"),
        ("0.1+0.2", "0.3"),
        ("2^0.5", "1.414213562"),
        ("2^-1", "0.5"),
        ("(-3)^2", "9"),
    ])
    func arithmetic(input: String, expected: String) {
        #expect(Calculator.evaluate(input)?.text == expected)
    }

    @Test(arguments: ["Safari", "42", "-5", "Wi-Fi", "2 3", "(", "1/0", "sqrt(", "System Settings"])
    func notACalculation(input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test(arguments: [
        ("5 km in miles", "3.106855961 mi"),
        ("72 f to c", "22.22222222 °C"),
        ("100c in f", "212 °F"),
        ("1.5 gb in mb", "1500 MB"),
        ("6 ft in m", "1.8288 m"),
        ("12 in in cm", "30.48 cm"),
        ("2 lbs to kg", "0.90718474 kg"),
    ])
    func conversions(input: String, expected: String) {
        #expect(Calculator.evaluate(input)?.text == expected)
    }

    @Test func refusesMismatchedUnits() {
        #expect(Calculator.evaluate("5 km in kg") == nil)
        #expect(Calculator.evaluate("open in finder") == nil)
    }
}

@Suite struct ClipboardHistoryTests {
    @Test func newestFirstWithoutDuplicates() {
        var history = ClipboardHistory()
        history.add("one")
        history.add("two")
        history.add("one")
        #expect(history.entries.map(\.text) == ["one", "two"])
    }

    @Test func skipsBlankAndHugeCopies() {
        var history = ClipboardHistory(maxLength: 10)
        history.add("   \n")
        history.add(String(repeating: "x", count: 11))
        #expect(history.entries.isEmpty)
    }

    @Test func keepsOnlyTheLimit() {
        var history = ClipboardHistory(limit: 3)
        for i in 1...5 { history.add("item \(i)") }
        #expect(history.entries.map(\.text) == ["item 5", "item 4", "item 3"])
    }

    @Test func searchNeedsEveryWord() {
        var history = ClipboardHistory()
        history.add("git push origin main")
        history.add("ssh desktop")
        #expect(history.search("push main").map(\.text) == ["git push origin main"])
        #expect(history.search("").count == 2)
    }
}

@Suite struct ServiceTests {
    @Test(arguments: [
        ("check example.com", "example.com"),
        ("Check  masonkimball.dev ", "masonkimball.dev"),
        ("check", nil),
        ("check my site", nil),
        ("checkers.app", nil),
    ] as [(String, String?)])
    func checkCommand(input: String, expected: String?) {
        #expect(CheckupClient.site(fromCommand: input) == expected)
    }

    @Test func decodesHomebaseStatus() throws {
        let json = #"{"apps":[{"name":"shelf","title":"Shelf (media)","state":"running","restarts":0,"autostart":true}]}"#
        struct Status: Decodable { let apps: [HomebaseClient.App] }
        let apps = try JSONDecoder().decode(Status.self, from: Data(json.utf8)).apps
        #expect(apps.first?.displayName == "Shelf (media)")
        #expect(apps.first?.isRunning == true)
    }
}

@Suite struct AppIndexTests {
    @Test func findsSystemApps() {
        let apps = AppIndex.scan()
        let names = Set(apps.map(\.name))
        #expect(names.contains("Calculator"))
        // A symlink into a system cryptex on recent macOS, which a hidden-file
        // filter used to drop.
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            #expect(names.contains("Safari"))
        }
        #expect(names.contains("Finder"))
        #expect(apps.allSatisfy { $0.url.pathExtension == "app" })
    }
}
