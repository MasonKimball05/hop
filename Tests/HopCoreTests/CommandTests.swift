import Foundation
import Testing
@testable import HopCore

@Suite struct RepoTests {
    @Test func parsesBranchAheadBehindAndChanges() {
        let out = "## main...origin/main [ahead 2, behind 1]\n M Sources/a.swift\n?? new.txt\n"
        let s = Repos.parseStatus(out)
        #expect(s.branch == "main" && s.ahead == 2 && s.behind == 1 && s.changed == 2)
        #expect(s.summary == "main \u{00B7} 2 changed \u{00B7} 2 to push \u{00B7} 1 to pull")
    }

    @Test func parsesCleanAndUnusualHeaders() {
        #expect(Repos.parseStatus("## main...origin/main\n").summary == "main \u{00B7} clean")
        #expect(Repos.parseStatus("## No commits yet on main\n").branch == "main")
        #expect(Repos.parseStatus("## HEAD (no branch)\n").branch == nil)
        #expect(Repos.parseStatus("## feature/x\n").branch == "feature/x")
    }

    @Test(arguments: [
        ("git@github.com:MasonKimball05/hop.git", "https://github.com/MasonKimball05/hop"),
        ("https://github.com/MasonKimball05/hop.git", "https://github.com/MasonKimball05/hop"),
        ("ssh://git@github.com/MasonKimball05/hop.git", "https://github.com/MasonKimball05/hop"),
        ("/some/local/path", nil),
    ] as [(String, String?)])
    func remoteToWebURL(remote: String, expected: String?) {
        #expect(Repos.webURL(fromRemote: remote)?.absoluteString == expected)
    }

    @Test func picksTheRightIDE() {
        #expect(Repos.preferredIDE(forFilesAt: ["Package.swift", "README.md"]) == .xcode)
        #expect(Repos.preferredIDE(forFilesAt: ["MediaPlayer.xcodeproj"]) == .xcode)
        #expect(Repos.preferredIDE(forFilesAt: ["go.mod", "main.go"]) == .goland)
        #expect(Repos.preferredIDE(forFilesAt: ["manage.py"]) == .pycharm)
        #expect(Repos.preferredIDE(forFilesAt: ["pom.xml"]) == .intellij)
        #expect(Repos.preferredIDE(forFilesAt: ["package.json"]) == .vscode)
    }

    @Test func scanFindsOnlyGitFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "a/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Repos.scan(root).map(\.name) == ["a"])
    }
}

@Suite struct PortTests {
    @Test func parsesLsofFieldsAndDedupes() {
        let out = "p501\ncnode\nn127.0.0.1:3000\nn[::1]:3000\np777\ncpostgres\nn*:5432\n"
        let ports = Ports.parse(out)
        #expect(ports.map(\.port) == [3000, 5432])
        #expect(ports[0].command == "node" && ports[0].pid == 501 && ports[0].isLocalOnly)
        #expect(!ports[1].isLocalOnly)
    }

    @Test(arguments: [("port 3000", 3000), ("ports", 0), ("Port 8090", 8090), ("port abc", nil), ("port 70000", nil), ("portfolio", nil)] as [(String, Int?)])
    func command(input: String, expected: Int?) {
        #expect(Ports.query(fromCommand: input) == expected)
    }
}

@Suite struct QuicklinkTests {
    @Test func searchFillsAndEncodesTheQuery() throws {
        let (link, query) = try #require(Quicklinks.search("g c++ & rust", in: Quicklinks.defaults))
        #expect(link.name == "Google")
        #expect(link.url(for: query)?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    @Test func keywordMustBeWholeAndHaveAQuery() {
        #expect(Quicklinks.search("gx thing", in: Quicklinks.defaults) == nil)
        #expect(Quicklinks.search("g ", in: Quicklinks.defaults) == nil)
        #expect(Quicklinks.search("Parliament", in: Quicklinks.defaults) == nil)
    }

    @Test func configFileKeepsABrokenFileForFixing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ConfigFile.load("links.json", defaults: [Quicklink(name: "A", url: "https://a")], in: folder)
        #expect(first.value.count == 1 && first.error == nil)
        try Data("[{oops".utf8).write(to: folder.appending(path: "links.json"))
        let broken = ConfigFile.load("links.json", defaults: [Quicklink(name: "A", url: "https://a")], in: folder)
        #expect(broken.error != nil)
        #expect(try String(contentsOf: folder.appending(path: "links.json"), encoding: .utf8) == "[{oops")
    }
}

@Suite struct DateMathTests {
    // Friday, October 2, 2026, 5:00 PM in Chicago (22:00 UTC).
    let math = DateMath(now: Date(timeIntervalSince1970: 1_790_978_400), timeZone: TimeZone(identifier: "America/Chicago")!)

    @Test func timeElsewhere() {
        #expect(math.evaluate("time in berlin")?.text == "12:00 AM GMT+2, Sat")
        #expect(math.evaluate("tokyo time")?.text == "7:00 AM GMT+9, Sat")
    }

    @Test(arguments: [
        ("3pm cst in pst", "1:00 PM PDT, Fri"),
        ("15:00 berlin to et", "9:00 AM EDT, Sat"),
        ("9:30am in utc", "2:30 PM GMT, Fri"),
        ("noon birmingham in berlin", "7:00 PM GMT+2, Fri"),
    ])
    func convertsTimes(input: String, expected: String) {
        #expect(math.evaluate(input)?.text == expected)
    }

    @Test func daysUntilAndSince() {
        #expect(math.evaluate("days until may 15 2027")?.text == "225 days (32.1 weeks)")
        #expect(math.evaluate("days since sep 25 2026")?.text == "7 days")
    }

    @Test func offsets() {
        #expect(math.evaluate("30 days from now")?.text == "Sunday, November 1, 2026")
        #expect(math.evaluate("2 weeks ago")?.text == "Friday, September 18, 2026")
        #expect(math.evaluate("1 month before may 15 2027")?.text == "Thursday, April 15, 2027")
    }

    @Test func unixTime() {
        #expect(math.evaluate("unix")?.text == "1790978400")
        #expect(math.evaluate("1790978400")?.text == "Fri, Oct 2, 2026 at 5:00 PM CDT")
        #expect(math.evaluate("1790978400000")?.text == "Fri, Oct 2, 2026 at 5:00 PM CDT")
    }

    @Test(arguments: ["Safari", "5 km in mi", "12 in in cm", "1234567", "time in narnia", "3 in pst", "days until whenever"])
    func ignoresOtherInput(input: String) {
        #expect(math.evaluate(input) == nil)
    }
}

@Suite struct SnippetTests {
    @Test func expandsPlaceholders() {
        let s = Snippet(name: "x", text: "On {date} at {time} ({isodate}): {clipboard}")
        let out = s.expanded(now: Date(timeIntervalSince1970: 1_790_978_400), clipboard: "hello",
                             timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(out == "On Oct 2, 2026 at 5:00 PM (2026-10-02): hello")
    }

    @Test func searchesNameAndText() {
        let all = [Snippet(name: "Address", text: "123 Main St"), Snippet(name: "Email", text: "me@example.com")]
        #expect(Snippets.search("main", in: all).map(\.name) == ["Address"])
        #expect(Snippets.search("", in: all).map(\.name) == ["Address", "Email"])
    }
}

@Suite struct DesktopServiceTests {
    @Test func shelfItemURLMatchesMediaPlayersForm() throws {
        let json = #"{"id":"0123456789abcdef01234567","root":"Movies","path":"Sci-Fi/Arrival (2016).mkv","name":"Arrival (2016).mkv","kind":"video","size":10,"position":754.5,"duration":6960}"#
        let file = try JSONDecoder().decode(ShelfSearchClient.File.self, from: Data(json.utf8))
        #expect(file.itemURL?.absoluteString == "shelf://0123456789abcdef01234567/Arrival%20(2016).mkv")
        #expect(file.position == 754.5 && file.isVideo)
    }

    @Test func jobTrackerPages() {
        let client = JobTrackerClient(base: URL(string: "http://desktop:5206")!)
        #expect(client.page(for: 12).absoluteString == "http://desktop:5206/applications/12")
        #expect(client.newJobPage(postingURL: "https://jobs.example/a?b=1&c=2").absoluteString
                == "http://desktop:5206/new?url=https://jobs.example/a?b%3D1%26c%3D2")
        #expect(client.newJobPage(postingURL: nil).absoluteString == "http://desktop:5206/new")
    }

    @Test func decodesJobTrackerFeed() throws {
        let json = #"[{"id":289,"company":"Notion","title":"SWE, New Grad","location":null,"remote":true,"score":85,"verdict":"Excellent fit","url":"https://jobs.example/1"}]"#
        let matches = try JSONDecoder().decode([JobTrackerClient.Match].self, from: Data(json.utf8))
        #expect(matches.first?.score == 85 && matches.first?.location == nil)
    }
}
