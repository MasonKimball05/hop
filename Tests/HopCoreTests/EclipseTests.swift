import Foundation
import SQLite3
import Testing
@testable import HopCore

@Suite struct EclipseTests {
    private let sample = #"""
    {"version": 3, "active_space_id": "s1",
     "favorites": [{"id": "f1", "url": "https://youtube.com", "title": "YouTube", "custom_title": null, "last_active": 100.0}],
     "spaces": [
       {"id": "s1", "name": "School", "icon": "ph.wrench",
        "pinned": [{"type": "folder", "id": "d1", "name": "COSC 470", "children": [
                      {"id": "t1", "url": "https://canvas.samford.edu/courses/470", "title": "Course", "custom_title": "COSC 470 Canvas", "last_active": 300.0}]}],
        "today": [{"id": "t2", "url": "https://docs.python.org/3/", "title": "", "last_active": "200.5"},
                  {"id": "broken"}]},
       {"id": "s2", "name": "Games", "icon": "🎮", "pinned": [], "today": []}],
     "history": [{"url": "https://swift.org/documentation/", "title": "Swift Documentation", "ts": 500.0, "visits": 3},
                 {"url": "https://www.swift.org/blog/", "title": "Swift Blog", "ts": 400.0, "visits": 1},
                 {"url": "https://swift.org/documentation/", "title": "Swift Documentation", "ts": 300.0, "visits": 3}]}
    """#

    private var session: Eclipse.Session { Eclipse.session(from: Data(sample.utf8))! }

    @Test func readsTabsFromFoldersSpacesAndFavorites() {
        #expect(session.spaces.map(\.name) == ["School", "Games"])
        #expect(session.spaces[1].icon == "🎮")
        #expect(session.tabs.map(\.id) == ["f1", "t1", "t2"])           // the broken entry is skipped
        let canvas = session.tabs[1]
        #expect(canvas.title == "COSC 470 Canvas" && canvas.space == "School" && canvas.section == .pinned)
        #expect(session.tabs[2].title == "https://docs.python.org/3/")   // empty title: the address
        #expect(session.tabs[2].lastActive == Date(timeIntervalSince1970: 200.5))  // written as text
        #expect(session.tabs[0].space == nil && session.tabs[0].section == .favorites)
    }

    @Test func searchesTabsAndHistory() {
        #expect(Eclipse.tabs(matching: "", in: session).map(\.id) == ["t1", "t2", "f1"])   // most recent first
        #expect(Eclipse.tabs(matching: "canvas 470", in: session).map(\.id) == ["t1"])
        #expect(Eclipse.tabs(matching: "school python", in: session).map(\.id) == ["t2"])   // by Space too
        #expect(Eclipse.history(matching: "swift", in: session).map(\.url) == ["https://swift.org/documentation/", "https://www.swift.org/blog/"])
        #expect(Eclipse.history(matching: "blog swift", in: session).count == 1)
    }

    @Test func readsTypedCommands() {
        #expect(Eclipse.tabQuery("tab canvas") == "canvas" && Eclipse.tabQuery("tabs") == "")
        #expect(Eclipse.spaceQuery("space school") == "school")
        #expect(Eclipse.historyQuery("h swift docs") == "swift docs" && Eclipse.historyQuery("h") == nil)
        #expect(Eclipse.pageQuery("page diffie hellman") == "diffie hellman")
        #expect(Eclipse.tabQuery("table") == nil && Eclipse.historyQuery("hello") == nil && Eclipse.spaceQuery("spacex") == nil)
    }

    @Test func buildsLinksEclipseCanRead() {
        let open = Eclipse.openLink("https://example.com/a?b=1&c=d+e", space: "School")!.absoluteString
        #expect(open == "eclipse-browser://open?space=School&url=https://example.com/a?b%3D1%26c%3Dd%2Be")
        #expect(Eclipse.openLink("file:///etc/passwd") == nil)
        #expect(Eclipse.spaceLink("Christianity")!.absoluteString == "eclipse-browser://space?name=Christianity")
        #expect(Eclipse.searchLink("c++ templates")!.absoluteString == "eclipse-browser://search?q=c%2B%2B%20templates")
        // Eclipse decodes with Python's parse_qs: check the round trip the same way.
        let items = URLComponents(url: Eclipse.openLink("https://x.com/?q=a+b&r=1")!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "url" }?.value == "https://x.com/?q=a+b&r=1")
    }

    @Test func searchesThePageIndex() throws {
        #expect(Eclipse.ftsQuery("diffie hell") == "\"diffie\" \"hell\"*")
        #expect(Eclipse.ftsQuery("say \"hi\"") == "\"say\" \"hi\"*")
        #expect(Eclipse.ftsQuery("  ") == nil)

        let folder = FileManager.default.temporaryDirectory.appending(path: "eclipse-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "pages.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE VIRTUAL TABLE pages USING fts5(url UNINDEXED, title, body, visited UNINDEXED, tokenize = 'porter unicode61 remove_diacritics 2');
            INSERT INTO pages VALUES ('https://crypto.example/dh', 'Key exchange', 'The Diffie-Hellman key exchange lets two parties agree on a secret.', 1);
            INSERT INTO pages VALUES ('https://cooking.example', 'Pasta', 'Boil the water first.', 2);
            """, nil, nil, nil)
        sqlite3_close(db)

        let hits = Eclipse.searchPages("diffie hell", database: file)
        #expect(hits.map(\.url) == ["https://crypto.example/dh"])
        #expect(hits.first?.snippet.contains("«Diffie»") == true)
        #expect(Eclipse.searchPages("nothing like this", database: file).isEmpty)
        #expect(Eclipse.searchPages("x", database: folder.appending(path: "missing.db")).isEmpty)
    }
}

@Suite struct EclipseMoreTests {
    private let sample = #"""
    {"active_space_id": "s2",
     "favorites": [],
     "spaces": [
       {"id": "s1", "name": "School", "pinned": [
          {"type": "folder", "id": "lf1", "name": "COSC 470 Feed",
           "live": {"source": "https://feed.example/rss", "seen": ["https://feed.example/1"], "refreshed": 1000.0},
           "children": [{"id": "a", "url": "https://feed.example/1", "title": "Old post", "home_url": "https://feed.example/1"},
                        {"id": "b", "url": "https://feed.example/2?clicked=1", "title": "New post", "home_url": "https://feed.example/2"},
                        {"type": "folder", "id": "sub", "name": "Issues", "children": [
                           {"id": "c", "url": "https://github.com/x/y/issues/9", "title": "Issue 9", "home_url": "https://github.com/x/y/issues/9"}]}]},
          {"type": "folder", "id": "lf2", "name": "Never refreshed", "live": {"source": "https://feed.example/rss2"},
           "children": [{"id": "d", "url": "https://feed.example/x", "title": "X"}]}], "today": []},
       {"id": "s2", "name": "Games", "pinned": [], "today": []}],
     "history": [],
     "archive": [{"url": "https://canvas.example/a", "title": "Canvas", "space_id": "s1", "archived_at": 50.0},
                 {"url": "https://gone.example", "title": "", "space_id": "deleted", "archived_at": 80.0}],
     "settings": {"page_watches": [
        {"id": "w1", "url": "https://shop.example/item", "title": "Camera", "changed": 900.0, "summary": "Price dropped to $249", "paused": false},
        {"id": "w2", "url": "https://jobs.example", "title": "", "changed": null, "summary": "", "paused": true}]}}
    """#

    private var session: Eclipse.Session { Eclipse.session(from: Data(sample.utf8))! }

    @Test func readsTheActiveSpaceAndArchive() {
        #expect(session.activeSpace == "Games")
        #expect(session.archived.map(\.title) == ["https://gone.example", "Canvas"])   // newest first
        #expect(session.archived.map(\.space) == [nil, "School"])
        #expect(Eclipse.archived(matching: "school canvas", in: session).count == 1)
        #expect(Eclipse.archiveQuery("archive canvas") == "canvas" && Eclipse.archiveQuery("archived") == "")
    }

    @Test func countsNewLiveFolderItemsTheWayEclipseDoes() {
        let folders = session.liveFolders
        #expect(folders.map(\.name) == ["COSC 470 Feed", "Never refreshed"])
        // By feed address (home_url), sub-folders included; seen ones left out.
        #expect(folders[0].new.map(\.url) == ["https://feed.example/2", "https://github.com/x/y/issues/9"])
        #expect(folders[0].space == "School")
        // Before its first refresh, everything in it counts as seen.
        #expect(folders[1].new.isEmpty)
    }

    @Test func readsPageWatches() {
        let watches = session.pageWatches
        #expect(watches.map(\.id) == ["w1", "w2"])
        #expect(watches[0].changed == Date(timeIntervalSince1970: 900) && watches[0].summary == "Price dropped to $249")
        #expect(watches[1].changed == nil && watches[1].paused && watches[1].title == "https://jobs.example")
    }

    @Test func listsAndSearchesNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "eclipse-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Essay ideas\n\nCompare Locke and Hobbes".write(to: folder.appending(path: "n1.md"), atomically: true, encoding: .utf8)
        try "".write(to: folder.appending(path: "n2.md"), atomically: true, encoding: .utf8)
        try "not a note".write(to: folder.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        let notes = Eclipse.notes(in: folder)
        #expect(Set(notes.map(\.title)) == ["Essay ideas", "Untitled Note"])
        #expect(Eclipse.notes(matching: "locke hobbes", in: notes).map(\.id) == ["n1"])
        #expect(Eclipse.noteQuery("note essay") == "essay" && Eclipse.noteQuery("notes") == "")
        #expect(Eclipse.noteLink("n1")!.absoluteString == "eclipse-browser://note?id=n1")
    }

    @Test func readsAPagesWholeText() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "eclipse-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "pages.db")
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(db, """
            CREATE VIRTUAL TABLE pages USING fts5(url UNINDEXED, title, body, visited UNINDEXED);
            INSERT INTO pages VALUES ('https://syllabus.example', 'COSC 470 Syllabus', 'Midterm on Oct 22. Lab 7 due Oct 23.', 1);
            """, nil, nil, nil)
        sqlite3_close(db)
        let page = Eclipse.pageText(for: "https://syllabus.example", database: file)
        #expect(page?.title == "COSC 470 Syllabus" && page?.text.contains("Lab 7 due") == true)
        #expect(Eclipse.pageText(for: "https://not-indexed.example", database: file) == nil)
    }
}

@Suite struct HopLinkTests {
    private func parse(_ text: String) -> HopLink? { HopLink.parse(URL(string: text)!) }

    @Test func readsEachAction() {
        #expect(parse("hop://open?q=tab%20canvas") == .open(query: "tab canvas"))
        #expect(parse("hop://") == .open(query: nil))
        #expect(parse("hop://ask?q=Summarize%20this&page=https://example.com/a&title=A%20page")
                == .ask(question: "Summarize this", page: "https://example.com/a", title: "A page", text: nil))
        #expect(parse("hop://focus?minutes=45&label=calc") == .focus(minutes: 45, label: "calc"))
        #expect(parse("hop://focus") == .focus(minutes: 25, label: nil))
        #expect(parse("hop://deadlines?page=https://canvas.example/syllabus") == .deadlines(page: "https://canvas.example/syllabus", title: nil))
        #expect(parse("hop://brief") == .brief)
    }

    @Test func refusesWhatItShouldNot() {
        #expect(parse("hop://focus?minutes=0") == nil)
        #expect(parse("hop://delete-everything") == nil)
        #expect(parse("https://example.com") == nil)
        // A link can't point Hop at a local file.
        #expect(parse("hop://ask?page=file:///etc/passwd") == .ask(question: nil, page: nil, title: nil, text: nil))
        // Attached text is capped.
        if case .ask(_, _, _, let text)? = parse("hop://ask?text=" + String(repeating: "a", count: HopLink.maxText + 50)) {
            #expect(text?.count == HopLink.maxText)
        } else {
            Issue.record("not an ask link")
        }
    }

    @Test func dueDatesFromAPagesText() {
        let prompt = Deadlines.prompt(page: (title: "COSC 470 Syllabus", text: "Lab 7 due Oct 23."))
        #expect(prompt.contains("in the web page \u{201C}COSC 470 Syllabus\u{201D}") && prompt.hasSuffix("Lab 7 due Oct 23."))
        #expect(Deadlines.prompt().contains("on this screen"))
    }
}

@Suite struct FocusSpaceTests {
    private let spaces = ["Personal", "School", "Games"].map { Eclipse.Space(id: $0, name: $0, icon: nil) }

    @Test func picksTheSpaceTheLabelNamesElseTheSetting() {
        #expect(Eclipse.focusSpace(label: "school", setting: "", spaces: spaces) == "School")
        #expect(Eclipse.focusSpace(label: "calc in school", setting: "", spaces: spaces) == "School")
        #expect(Eclipse.focusSpace(label: "calc", setting: "", spaces: spaces) == nil)          // only from the label
        #expect(Eclipse.focusSpace(label: "calc", setting: "School", spaces: spaces) == "School")
        #expect(Eclipse.focusSpace(label: "games", setting: "School", spaces: spaces) == "Games") // the label wins
        #expect(Eclipse.focusSpace(label: "school", setting: Eclipse.focusSpaceNever, spaces: spaces) == nil)
        #expect(Eclipse.focusSpace(label: nil, setting: "Deleted Space", spaces: spaces) == nil)
    }
}
