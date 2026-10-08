import Foundation
import Testing
@testable import HopCore

@Suite struct DaybookTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func log(_ text: String, now: Date) -> (String, Date, Date)? {
        guard case .log(let title, let start, let end)? = Daybook.command(text, now: now, calendar: cal) else { return nil }
        return (title, start, end)
    }

    @Test func tasksAndEvents() {
        #expect(Daybook.command("task submit report friday 3pm") == .addTask("submit report friday 3pm"))
        #expect(Daybook.command("todo call mom") == .addTask("call mom"))
        #expect(Daybook.command("event coffee with Sam thu 2pm") == .addEvent("coffee with Sam thu 2pm"))
        #expect(Daybook.command("task") == nil)
        #expect(Daybook.command("tasks for today") == nil)
    }

    @Test func logRanges() throws {
        let night = at(7, 23, 30)
        let study = try #require(log("log study 10-11pm", now: night))
        #expect(study.0 == "Study" && study.1 == at(7, 22) && study.2 == at(7, 23))
        let gym = try #require(log("log gym from 9:30am to 11", now: night))
        #expect(gym.0 == "Gym" && gym.1 == at(7, 9, 30) && gym.2 == at(7, 11))
        let lab = try #require(log("log lab 11-1pm", now: night))   // 11 AM to 1 PM
        #expect(lab.1 == at(7, 11) && lab.2 == at(7, 13))
        // Just after midnight, last night's 10 to 11 PM is yesterday's.
        let late = try #require(log("log study 10-11pm", now: at(8, 0, 30)))
        #expect(late.1 == at(7, 22) && late.2 == at(7, 23))
    }

    @Test func logLengthsEndNow() throws {
        let now = at(7, 15)
        let reading = try #require(log("log reading 90m", now: now))
        #expect(reading.0 == "Reading" && reading.1 == at(7, 13, 30) && reading.2 == now)
        let piano = try #require(log("log piano for 1.5h", now: now))
        #expect(piano.1 == at(7, 13, 30))
        #expect(log("log study", now: now) == nil)       // no time
        #expect(log("log 10-11pm", now: now) == nil)      // no name
    }

    @Test func links() {
        #expect(Daybook.link(for: .addTask("call mom friday")).absoluteString == "daybook://add-task?text=call%20mom%20friday")
        #expect(Daybook.completeLink(taskID: "ABC").absoluteString == "daybook://complete-task?id=ABC")
        #expect(Daybook.showLink("time").absoluteString == "daybook://show?view=time")
        #expect(Daybook.showLink(nil).absoluteString == "daybook://brief")
        let url = Daybook.link(for: .log(title: "Study", start: at(7, 22), end: at(7, 23))).absoluteString
        #expect(url == "daybook://log?title=Study&start=2026-10-08T03:00:00Z&end=2026-10-08T04:00:00Z")
    }

    @Test func readsTheFeed() throws {
        let json = """
        {"updated":"2026-10-07T20:00:00Z","today":[
          {"title":"Fair","start":"2026-10-07T05:00:00Z","end":"2026-10-08T05:00:00Z","allDay":true,"calendar":"Home"},
          {"title":"Lab","start":"2026-10-07T21:00:00Z","end":"2026-10-07T22:00:00Z","allDay":false,"calendar":"Samford","place":"Brooks 210"}],
         "tasks":[{"id":"r1","title":"Essay","due":"2026-10-07T05:00:00Z","hasTime":false,"overdue":false,"priority":"high"}],
         "countdowns":[{"title":"Lab 6","date":"2026-10-09T05:00:00Z","days":2}],
         "waitingOnReplies":1,"codingHoursToday":4.06,"commitsToday":11}
        """
        let feed = try #require(Daybook.decode(Data(json.utf8)))
        #expect(feed.next(after: at(7, 15))?.title == "Lab")     // all-day items aren't "next"
        #expect(feed.tasks.first?.priority == "high")
        #expect(Daybook.countdown(to: at(7, 16), end: at(7, 17), now: at(7, 15, 35)) == "in 26 min")
        #expect(Daybook.countdown(to: at(7, 15), end: at(7, 16), now: at(7, 15, 30)) == "now")
    }
}
