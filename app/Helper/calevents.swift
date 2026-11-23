// Prints calendar events as JSON: [{"id","title","start","end","calendar","allDay","recurring"}]
//   calevents [DAYS] [OFFSET]   DAYS days of events (default 1), starting OFFSET days from today (default 0)
// A day runs 4am to 4am, like the app's stats, so "today" at 1am is still the day before.
import EventKit
import Foundation

let args = CommandLine.arguments
let days = args.count > 1 ? max(1, Int(args[1]) ?? 1) : 1
let offset = args.count > 2 ? Int(args[2]) ?? 0 : 0
let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
sem.wait()
guard granted else { print("{\"error\":\"no calendar access\"}"); exit(1) }
let cal = Calendar.current
let planDay = cal.startOfDay(for: Date().addingTimeInterval(-4 * 3600))
let start = cal.date(byAdding: .day, value: offset, to: planDay)!
let end = cal.date(byAdding: .day, value: days, to: start)!
let fmt = ISO8601DateFormatter(); fmt.timeZone = .current; fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
let skip: Set<String> = ["Birthdays", "Siri Suggestions", "Scheduled Reminders"]
let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    .filter { !skip.contains($0.calendar.title) && $0.calendar.type != .birthday }
    .map { ["id": $0.eventIdentifier ?? "", "title": $0.title ?? "", "start": fmt.string(from: $0.startDate), "end": fmt.string(from: $0.endDate),
            "calendar": $0.calendar.title, "allDay": $0.isAllDay, "recurring": $0.hasRecurrenceRules] as [String: Any] }
let data = try! JSONSerialization.data(withJSONObject: events, options: [])
print(String(data: data, encoding: .utf8)!)
