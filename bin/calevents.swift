// Prints today's (or N days') calendar events as JSON: [{"title","start","end","calendar","allDay"}]
import EventKit
import Foundation

let days = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1 : 1
let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
}
sem.wait()
guard granted else { print("{\"error\":\"no calendar access\"}"); exit(1) }
let cal = Calendar.current
let start = cal.startOfDay(for: Date())
let end = cal.date(byAdding: .day, value: days, to: start)!
let fmt = ISO8601DateFormatter(); fmt.timeZone = .current; fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
let skip: Set<String> = ["Birthdays", "Siri Suggestions", "Scheduled Reminders"]
let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    .filter { !skip.contains($0.calendar.title) }
    .map { ["title": $0.title ?? "", "start": fmt.string(from: $0.startDate), "end": fmt.string(from: $0.endDate),
            "calendar": $0.calendar.title, "allDay": $0.isAllDay] as [String: Any] }
let data = try! JSONSerialization.data(withJSONObject: events, options: [])
print(String(data: data, encoding: .utf8)!)
