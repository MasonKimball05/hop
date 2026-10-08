import AppKit
import HopCore

// Daybook: today's events, tasks due and countdowns from Daybook's hop.json,
// and typed commands ("task …", "event …", "log study 10-11pm") sent to it as
// daybook:// links. See HopCore/Daybook.swift.
extension LauncherModel {
    func daybookRows() -> [Row] {
        guard let feed = Daybook.readFeed() else {
            return [Row(id: "db-missing", title: "Daybook hasn\u{2019}t written anything yet",
                        subtitle: "Open Daybook once; it shares today with hop from then on", icon: .symbol("calendar"),
                        actionName: "Open Daybook") { [unowned self] in sendToDaybook(Daybook.showLink("today"), activate: true) }]
        }
        let now = Date.now
        var out: [Row] = []
        for event in feed.today {
            let when = event.allDay ? "All day"
                : "\(event.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(event.end.formatted(date: .omitted, time: .shortened))"
            out.append(Row(id: "db-e:\(event.title)\(event.start)", title: event.title,
                           subtitle: [when, event.calendar, event.place].compactMap { $0 }.joined(separator: " \u{00B7} "),
                           icon: .symbol("calendar", .systemBlue),
                           accessory: event.allDay ? nil : Daybook.countdown(to: event.start, end: event.end, now: now),
                           actionName: "Show in Daybook") { [unowned self] in sendToDaybook(Daybook.showLink("today"), activate: true) })
        }
        for task in feed.tasks {
            let flag = task.priority == "urgent" ? "!! " : task.priority == "high" ? "! " : ""
            var subtitle = task.overdue ? "Overdue" : "Due today"
            if task.hasTime, let due = task.due { subtitle += " \u{00B7} " + due.formatted(date: .omitted, time: .shortened) }
            out.append(Row(id: "db-t:" + task.id, title: flag + task.title, subtitle: subtitle,
                           icon: .symbol("circle", task.overdue ? .systemRed : .secondaryLabelColor),
                           actionName: "Check Off") { [unowned self] in
                sendToDaybook(Daybook.completeLink(taskID: task.id), activate: false)
                message = "Checked off \u{201C}\(task.title)\u{201D}"
            })
        }
        for countdown in feed.countdowns {
            out.append(Row(id: "db-c:\(countdown.title)", title: countdown.title,
                           subtitle: countdown.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                           icon: .symbol("hourglass", .systemPurple),
                           accessory: countdown.days <= 0 ? "Today" : countdown.days == 1 ? "Tomorrow" : "\(countdown.days) days"))
        }
        // A line on the rest of the day, then ways into Daybook.
        var status: [String] = []
        if feed.codingHoursToday > 0 { status.append(String(format: "%.1f h coding, %d commits today", feed.codingHoursToday, feed.commitsToday)) }
        if feed.waitingOnReplies > 0 { status.append("\(feed.waitingOnReplies) email\(feed.waitingOnReplies == 1 ? "" : "s") waiting on a reply") }
        if !status.isEmpty {
            out.append(Row(id: "db-status", title: status.joined(separator: " \u{00B7} "), subtitle: "Updated \(Self.relative(feed.updated))",
                           icon: .symbol("chevron.left.forwardslash.chevron.right", .systemOrange)))
        }
        out += [
            ("Open Daybook", "today", "calendar"), ("Time Recap", "time", "chart.bar"),
            ("Week", "week", "calendar.day.timeline.left"), ("Morning Brief", nil, "sun.horizon"),
        ].map { name, view, symbol in
            Row(id: "db-open:" + name, title: name, icon: .symbol(symbol), accessory: "Daybook", actionName: "Open") { [unowned self] in
                sendToDaybook(Daybook.showLink(view), activate: true)
            }
        }
        if query.isEmpty { return out }
        return out.filter { FuzzyMatcher.score(query, in: $0.title + " " + ($0.subtitle ?? "")) != nil }
    }

    /// A row for "task …", "event …" or "log …" typed in the main search.
    func daybookCommandRow(for text: String) -> Row? {
        guard let command = Daybook.command(text) else { return nil }
        let link = Daybook.link(for: command)
        switch command {
        case .addTask(let task):
            return Row(id: "db-add-task", title: "Add Task to Daybook: \(task)", subtitle: "Dates and times work: \u{201C}friday 3pm\u{201D}; !high or !urgent for priority",
                       icon: .symbol("checklist", .systemBlue), accessory: "Daybook", actionName: "Add Task") { [unowned self] in
                sendToDaybook(link, activate: false)
                hide()
            }
        case .addEvent(let event):
            return Row(id: "db-add-event", title: "Add Event to Daybook: \(event)", subtitle: "An hour long at the time given, or all day on a bare date",
                       icon: .symbol("calendar.badge.plus", .systemBlue), accessory: "Daybook", actionName: "Add Event") { [unowned self] in
                sendToDaybook(link, activate: false)
                hide()
            }
        case .log(let title, let start, let end):
            let minutes = Int(end.timeIntervalSince(start) / 60)
            let length = minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
            let day = Calendar.current.isDateInToday(start) ? "" : start.formatted(.dateTime.weekday(.abbreviated)) + " "
            return Row(id: "db-log", title: "Log \(title): \(day)\(start.formatted(date: .omitted, time: .shortened)) \u{2013} \(end.formatted(date: .omitted, time: .shortened))",
                       subtitle: "\(length), in Daybook\u{2019}s Time Log and the weekly recap", icon: .symbol("clock.badge.checkmark", .systemTeal),
                       accessory: "Daybook", actionName: "Log It") { [unowned self] in
                sendToDaybook(link, activate: false)
                hide()
            }
        }
    }

    /// With nothing typed: the next event, so opening hop tells you what's coming.
    func nextEventRow() -> Row? {
        guard let feed = Daybook.readFeed(), let next = feed.next() else { return nil }
        let when = Daybook.countdown(to: next.start, end: next.end)
        return Row(id: "db-next", title: "\(next.title) \u{00B7} \(when)",
                   subtitle: [next.start.formatted(date: .omitted, time: .shortened), next.place].compactMap { $0 }.joined(separator: " \u{00B7} "),
                   icon: .symbol("calendar", .systemBlue), accessory: "Next", actionName: "Show Today") { [unowned self] in enter(.daybook) }
    }

    /// Opens a daybook:// link. Adding things happens in the background, without
    /// bringing Daybook forward; showing a view does bring it forward.
    func sendToDaybook(_ url: URL, activate: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        if activate { hide() }
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.message = "Couldn\u{2019}t reach Daybook: \(error.localizedDescription)" }
        }
    }
}
