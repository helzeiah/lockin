import AppKit
import Foundation
import Security

/// The app's own name as macOS reports it, so its windows never count as another app.
let selfAppName = NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName

// Data lives in ~/Library/Application Support/lockin (the same files the Python helper reads and writes), or in
// $LOCKIN_DATA when that's set (tests and screenshots run against demo data that way).
// The helper scripts and the calendar reader ship inside the app bundle (Contents/Resources).
enum Paths {
    static let dir: URL = {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["LOCKIN_DATA"], !custom.isEmpty {
            let d = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = support.appendingPathComponent("lockin")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: d.appendingPathComponent("config.json").path) {
            // First launch: copy data from an older install (the app used to be called Focus), else start from the
            // example config. The old folder is left in place.
            let legacy = [support.appendingPathComponent("Focus")]
            if let old = legacy.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }) {
                for f in ["config.json", "todos.json", "state.json", "log.jsonl"] {
                    try? fm.copyItem(at: old.appendingPathComponent(f), to: d.appendingPathComponent(f))
                }
            } else {
                try? fm.copyItem(at: resources.appendingPathComponent("config.example.json"), to: d.appendingPathComponent("config.json"))
            }
        }
        return d
    }()
    static let config = dir.appendingPathComponent("config.json")
    static let log = dir.appendingPathComponent("log.jsonl")
    static let todos = dir.appendingPathComponent("todos.json")
    static let state = dir.appendingPathComponent("state.json")
    static let tasks = dir.appendingPathComponent("tasks.json")      // the running to-do list
    // build.sh copies these into Contents/Resources
    static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let coach = resources.appendingPathComponent("coach.py")
    static let calevents = resources.appendingPathComponent("calevents")
}

// The AI API key, kept in the login Keychain rather than in config.json.
enum Keychain {
    private static let service = "lockin AI API key"
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                             kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    static func get() -> String? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String?) {
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var q = base; q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// A task rule: tasks whose text mentions words from `name` get these apps, sites and Claude Code folders.
/// (Before v2 these were the "focus blocks" you picked by hand; old configs keep working as rules.)
struct Preset: Codable, Identifiable, Hashable {
    var name: String
    var minutes: Int
    var sites: [String]? = []
    var apps: [String]? = []
    var projects: [String]? = []
    var offline_ok: Bool? = false
    var any_claude: Bool? = false
    var terminal_ok: Bool? = true
    var strict: Bool? = false
    var id: String { name }
    var short: String { String(name.split(whereSeparator: { " /(".contains($0) }).first ?? Substring(name)) }
}

/// A session that repeats: added to the plan on each of its days (1 = Sunday ... 7 = Saturday).
struct Routine: Codable, Identifiable, Hashable {
    var id: String
    var task: String
    var minutes: Int
    var start: String              // "HH:MM"
    var days: [Int]
    var apps: [String]? = nil

    var daysLabel: String {
        let d = Set(days)
        if d.count == 7 { return "Every day" }
        if d == [2, 3, 4, 5, 6] { return "Weekdays" }
        if d == [1, 7] { return "Weekends" }
        let names = Calendar.current.shortWeekdaySymbols
        return days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ")
    }
}

struct Distractions: Codable { var apps: [String]; var sites: [String] }
struct AISettings: Codable { var provider: String? }

struct Config: Codable {
    var drift_seconds: Double? = 30
    var renudge_seconds: Double? = 120
    var break_minutes: Int? = 5          // a break's length when it doesn't scale with the session
    var break_ratio: Int? = nil          // a break is the session's length ÷ this (3-6); 0 = always break_minutes
    var recap_at: String? = "21:00"
    var morning_hour: Int? = 5
    var idle_nudge_minutes: Double? = 40
    var active_hours: [Int]? = [8, 23]
    var away_seconds: Double? = 45
    var mac_away_seconds: Double? = 180
    var distractions: Distractions
    var block_sites: [String]
    var always_ok_apps: [String]? = []
    var blocks: [Preset]                 // task rules
    var ai: AISettings? = nil
    var blocking: String? = "hard"       // "hard" = Locked (no passes, blocked apps get hidden) | "cover" = Strict (passes)
    var cover_sound: Bool? = true
    var stats_goal: Int? = 25            // focused minutes for a day to count toward the streak
    var stats_week_goal: Int? = 5        // days a week you want to hit that
    var sounds: Bool? = true
    var check_ins: Bool? = true          // "halfway" and "1 minute left" drop out of the notch
    var streak_reminder: String? = "20:00"
    // v2
    var lockin_apps: [String]? = []      // the apps every session allows unless a task rule or history says otherwise
    var morning_gate: Bool? = true       // the full-screen "start your day" screen, once a day
    var earn_free_time: Bool? = true     // outside sessions, distractions stay covered until today counts
    var free_passes: Int? = 3            // 5-minute passes a day while earning free time (Strict only)
    var auto_start: Bool? = true         // planned sessions start at their time after a short countdown
    var calendar_mode: String? = "ask"   // "ask": offer to lock in when an event starts | "off"
    var calendar_ignore: [String]? = []  // event titles never asked about
    var day_end: String? = "23:30"       // planned sessions that don't fit before this lose their time
    var routines: [Routine]? = []

    var aiOn: Bool { !["", "none"].contains(ai?.provider ?? "none") }
    /// Breaks scale with the session: its length ÷ this, or 0 for a fixed length. Configs from before this setting
    /// keep a break length you changed by hand; everyone else gets ÷ 5 (a 5-minute break after 25 minutes).
    var breakRatio: Int { break_ratio ?? ((break_minutes ?? 5) == 5 ? 5 : 0) }
    /// The break after a session this many minutes long. At least a minute.
    func breakAfter(_ minutes: Int) -> Int {
        breakRatio > 0 ? max(1, Int((Double(minutes) / Double(breakRatio)).rounded())) : max(1, break_minutes ?? 5)
    }
    var locked: Bool { (blocking ?? "hard") == "hard" }

    static func load() -> Config? {
        guard let d = try? Data(contentsOf: Paths.config) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }
    static let empty = Config(distractions: Distractions(apps: [], sites: []), block_sites: [], blocks: [])
}

/// Edits config.json in place, keeping keys the app doesn't know about.
func editConfig(_ change: (inout [String: Any]) -> Void) {
    var raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.config))) as? [String: Any] ?? [:]
    change(&raw)
    if let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: Paths.config) }
}

struct Todo: Codable, Identifiable, Hashable {
    var id: String
    var task: String
    var block: String = ""           // the task rule it matched, if any (shown, used for stats)
    var minutes: Int
    var start: String? = ""
    var done: Bool? = false
    var why: String? = ""
    var from: String? = nil          // backlog items: the day they were planned for
    var spent: Int? = 0              // minutes already worked on it in earlier, unfinished sessions
    var apps: [String]? = nil        // the apps this session allows; nil = decided when it starts
    var source: String? = nil        // "routine" (repeats) or "calendar"
    var ref: String? = nil           // the routine's id or the calendar event's id
    var pinned: Bool? = nil          // a time you set yourself: the plan flows around it until it goes by
    var task_id: String? = nil       // the to-do list task it came from
    var effort: Int? = nil           // how hard it is to get into: 1 easy, 2 medium, 3 hard (from the to-do list)
    // A piece of a bigger task, cut up for the day's commitment level: shared group, the task's name, which piece.
    var group: String? = nil
    var whole: String? = nil
    var part: Int? = nil
    var parts: Int? = nil
    var isDone: Bool { done ?? false }
    var left: Int { max(1, minutes - (spent ?? 0)) }
    var isRoutine: Bool { source == "routine" }

    static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    init(id: String, task: String, block: String = "", minutes: Int, start: String? = "", done: Bool? = false, why: String? = "",
         from: String? = nil, spent: Int? = 0, apps: [String]? = nil, source: String? = nil, ref: String? = nil, pinned: Bool? = nil, task_id: String? = nil, effort: Int? = nil) {
        self.id = id; self.task = task; self.block = block; self.minutes = minutes; self.start = start; self.done = done
        self.why = why; self.from = from; self.spent = spent; self.apps = apps; self.source = source; self.ref = ref
        self.pinned = pinned; self.task_id = task_id; self.effort = effort
    }

    /// Tolerant: only id, task and minutes have to be there (the helper script and older versions write fewer fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        task = try c.decode(String.self, forKey: .task)
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? Int((try? c.decode(Double.self, forKey: .minutes)) ?? 45)
        block = (try? c.decodeIfPresent(String.self, forKey: .block)) ?? ""
        start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? ""
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        spent = (try? c.decodeIfPresent(Int.self, forKey: .spent)) ?? 0
        apps = try? c.decodeIfPresent([String].self, forKey: .apps)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        ref = try? c.decodeIfPresent(String.self, forKey: .ref)
        pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
        task_id = try? c.decodeIfPresent(String.self, forKey: .task_id)
        effort = try? c.decodeIfPresent(Int.self, forKey: .effort)
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        whole = try? c.decodeIfPresent(String.self, forKey: .whole)
        part = try? c.decodeIfPresent(Int.self, forKey: .part)
        parts = try? c.decodeIfPresent(Int.self, forKey: .parts)
    }
}

struct ChatMsg: Codable, Hashable { var role: String; var text: String }

/// The shape of a day you're asked about when you plan it: longer breaks to keep free, and when work stops.
/// Sessions are only timed inside it. Saved with the plan, so having one at all means you've answered.
struct DayShape: Codable, Hashable {
    struct Break: Codable, Hashable { var start: String; var minutes: Int }   // "HH:MM"
    var breaks: [Break] = []
    var finish: String? = nil        // "HH:MM"; nil = the day_end setting

    /// The breaks as (start, end) on `day`.
    func busy(on day: Date) -> [(Date, Date)] {
        breaks.compactMap { b in parseHHMM(b.start, on: day).map { ($0, $0.addingTimeInterval(Double(b.minutes) * 60)) } }
    }
    /// "Lunch 12:30 PM for 1 hr · done by 6:00 PM", for the summary line.
    var summary: String {
        let br = breaks.map { "\(clockLabel($0.start)) for \(fmtMinutes($0.minutes))" }
        let parts = (br.isEmpty ? ["No long break"] : ["Break " + br.joined(separator: ", ")])
            + (finish.map { ["done by \(clockLabel($0))"] } ?? [])
        return parts.joined(separator: " · ")
    }

    /// Your last answer, offered as the starting point next time.
    static var last: DayShape? {
        get { UserDefaults.standard.data(forKey: "lastDayShape").flatMap { try? JSONDecoder().decode(DayShape.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastDayShape") }
    }
}

enum PlanDay: String, CaseIterable { case today, tomorrow }

struct TodoDoc: Codable {
    var date: String? = ""
    var items: [Todo] = []
    var chat: [ChatMsg]? = []
    var backlog: [Todo]? = []
    var tomorrow: [Todo]? = []
    var shape: DayShape? = nil            // today's breaks and finish time, once asked
    var tomorrow_shape: DayShape? = nil
    var level: Commitment? = nil          // how much you can commit to today; nil = you didn't say (sessions stay as planned)
    var tomorrow_level: Commitment? = nil

    init(date: String? = "", items: [Todo] = [], chat: [ChatMsg]? = [], backlog: [Todo]? = [], tomorrow: [Todo]? = []) {
        self.date = date; self.items = items; self.chat = chat; self.backlog = backlog; self.tomorrow = tomorrow
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        items = (try? c.decodeIfPresent([Todo].self, forKey: .items)) ?? []
        chat = try? c.decodeIfPresent([ChatMsg].self, forKey: .chat)
        backlog = try? c.decodeIfPresent([Todo].self, forKey: .backlog)
        tomorrow = try? c.decodeIfPresent([Todo].self, forKey: .tomorrow)
        shape = try? c.decodeIfPresent(DayShape.self, forKey: .shape)
        tomorrow_shape = try? c.decodeIfPresent(DayShape.self, forKey: .tomorrow_shape)
        level = try? c.decodeIfPresent(Commitment.self, forKey: .level)
        tomorrow_level = try? c.decodeIfPresent(Commitment.self, forKey: .tomorrow_level)
    }

    static func load() -> TodoDoc {
        let data = try? Data(contentsOf: Paths.todos)
        if let data, var doc = try? JSONDecoder().decode(TodoDoc.self, from: data) {
            if doc.date != today(), doc.rollover(routines: Config.load()?.routines ?? []) { doc.save() }
            return doc
        }
        // Unreadable (not missing): keep a copy rather than lose it, then start fresh.
        if let data { try? data.write(to: Paths.dir.appendingPathComponent("todos.unreadable.json")) }
        var doc = TodoDoc(date: today())
        doc.addRoutines(Config.load()?.routines ?? [])
        doc.save()
        return doc
    }

    /// New day: unfinished to-dos move to the backlog (shown in the planner, never nudged about), tomorrow's plan
    /// becomes today's, and today's repeating sessions are added.
    mutating func rollover(routines: [Routine], now: Date = Date()) -> Bool {
        let t = today(now)
        guard let d = date, !d.isEmpty else { date = t; addRoutines(routines, now: now); return true }
        guard d != t else { return false }
        var back = Dictionary((backlog ?? []).map { ($0.task.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // Plans for a day that already went by (away for a few days) land in the backlog too.
        let nextDay = DateFormatter.ymd.date(from: d).flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
        let tomorrowIsToday = nextDay.map { DateFormatter.ymd.string(from: $0) == t } ?? false
        // To-do list tasks aren't leftovers: they're still on the list.
        let leftovers = (items.filter { !$0.isDone && $0.source == nil } + (tomorrowIsToday ? [] : (tomorrow ?? []))).filter { $0.task_id == nil }
        for var item in leftovers {
            item.start = ""; item.why = ""; item.from = d
            back[item.task.lowercased()] = item
        }
        let cutoff = DateFormatter.ymd.string(from: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now)
        backlog = back.values.filter { ($0.from ?? t) >= cutoff }.sorted { ($0.from ?? "") > ($1.from ?? "") }
        items = tomorrowIsToday ? (tomorrow ?? []) : []
        shape = tomorrowIsToday ? tomorrow_shape : nil
        level = tomorrowIsToday ? tomorrow_level : nil
        tomorrow = []; tomorrow_shape = nil; tomorrow_level = nil; chat = []; date = t
        addRoutines(routines, now: now)
        sortItems()
        return true
    }

    /// Today's repeating sessions that aren't on the plan yet.
    mutating func addRoutines(_ routines: [Routine], now: Date = Date()) {
        let weekday = Calendar.current.component(.weekday, from: Stats.day(of: now))
        for r in routines where r.days.contains(weekday) && !items.contains(where: { $0.ref == r.id }) {
            items.append(Todo(id: Todo.newId(), task: r.task, minutes: r.minutes, start: r.start, apps: r.apps, source: "routine", ref: r.id))
        }
        sortItems()
    }

    /// By start time; finished items without a time first, unscheduled to-dos last.
    mutating func sortItems() {
        items = TodoDoc.sorted(items)
        tomorrow = TodoDoc.sorted(tomorrow ?? [])
    }
    static func sorted(_ list: [Todo]) -> [Todo] {
        func key(_ t: Todo) -> (Int, String) { !(t.start ?? "").isEmpty ? (1, t.start ?? "") : (t.isDone ? 0 : 2, "") }
        return list.enumerated().sorted { a, b in key(a.element) != key(b.element) ? key(a.element) < key(b.element) : a.offset < b.offset }.map(\.element)
    }
    func list(_ day: PlanDay) -> [Todo] { day == .today ? items : (tomorrow ?? []) }
    func shape(_ day: PlanDay) -> DayShape? { day == .today ? shape : tomorrow_shape }
    func level(_ day: PlanDay) -> Commitment? { day == .today ? level : tomorrow_level }
    mutating func edit(_ day: PlanDay, _ change: (inout [Todo]) -> Void) {
        if day == .today { change(&items) } else { var t = tomorrow ?? []; change(&t); tomorrow = t }
        sortItems()
    }

    /// The plan follows the day: today's open sessions re-timed in order, none before `from` (rounded up to 5 minutes),
    /// with a break after each (`breakAfter` its minutes) and around `busy` (calendar events). Repeats, calendar sessions and times you
    /// set yourself (while still ahead) keep their time and count as busy too. A session moves later only as far as it
    /// has to, so gaps in the plan absorb a delay. `freed` is the slot a session that finished or started early was
    /// planned for: the sessions queued right behind it move up, until the first real gap. `last` (a session ended
    /// early) goes after the rest. Ones that no longer fit before `dayEnd` lose their time; `keep` (the running
    /// session) and to-dos without a time aren't touched.
    static func retimed(_ items: [Todo], from: Date, busy: [(Date, Date)], dayEnd: Date, now: Date = Date(),
                        freed: (start: Date, end: Date)? = nil, keep: String? = nil, last: String? = nil,
                        breakAfter: (Int) -> Int = { _ in 5 }, pack: Bool = false) -> [Todo] {
        func at(_ t: Todo) -> Date? { parseHHMM(t.start ?? "", on: now) }
        func roundUp(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 300).rounded(.up) * 300) }
        func fixed(_ t: Todo) -> Bool { t.source != nil || ((t.pinned ?? false) && (at(t).map { $0 >= now } ?? false)) }
        var taken = busy
        for t in items where !t.isDone && t.id != keep && fixed(t) {
            if let a = at(t) { taken.append((a, a.addingTimeInterval(Double(t.left + breakAfter(t.left)) * 60))) }
        }
        // Pieces of a cut-up task are timed even before they have a time (right after the piece before them); other
        // untimed to-dos stay "any time".
        var queue = items.indices.filter { !items[$0].isDone && items[$0].id != keep && !fixed(items[$0])
                                           && (at(items[$0]) != nil || items[$0].part != nil) }
        if let last, let i = queue.firstIndex(where: { items[$0].id == last }) { queue.append(queue.remove(at: i)) }
        var out = items, cursor = roundUp(from), pull = freed
        for i in queue {
            let t = items[i], old = at(t) ?? cursor, len = Double(t.left) * 60, gap = Double(breakAfter(t.left)) * 60
            var s = pack ? cursor : max(old, cursor)   // pack: one after another in the order given, from `from`
            if let p = pull, t.id != last, old >= p.start {
                if old <= p.end.addingTimeInterval(600) { s = cursor; pull = (old, old.addingTimeInterval(len + gap)) }
                else { pull = nil }   // a real gap: everything after it stays where it is
            }
            var clear = false
            while !clear {
                clear = true
                for (a, b) in taken where s < b && s.addingTimeInterval(len) > a { s = roundUp(b); clear = false }
            }
            if s.addingTimeInterval(len) > dayEnd { out[i].start = ""; out[i].pinned = nil; continue }
            if hhmm(s) != t.start { out[i].start = hhmm(s); out[i].pinned = nil }
            cursor = roundUp(s.addingTimeInterval(len + gap))   // starts stay on 5-minute marks whatever the break
        }
        return out
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(self) { try? d.write(to: Paths.todos) }
    }
}

struct ActiveBlock: Codable {
    var kind: String          // "focus" | "break"
    var name: String          // what the time counts toward in Stats: the task rule, else the task
    var task: String?
    var todoId: String?
    var started: Double
    var ends: Double
    var minutes: Int
    var offSeconds: Double
    var apps: [String]? = nil   // the apps this session allows
    var snoozes: Int? = nil     // 5-minute passes used on covers this session
    var rule: String? = nil     // the task rule it matched, for its sites and Claude Code folders
    // What the time was actually spent on (seconds), so only real work counts:
    var activeSeconds: Double? = nil    // on task, with a key press, click or scroll in the last 90 seconds
    var offlineSeconds: Double? = nil   // away from the Mac on a task that allows it (paper, iPad)
    var idleSeconds: Double? = nil      // here, but nothing happening
    /// Minutes that count: active, plus away time on offline-ok tasks.
    var countedMinutes: Int { Int((((activeSeconds ?? 0) + (offlineSeconds ?? 0)) / 60).rounded()) }
    var tracked: Bool { activeSeconds != nil || offlineSeconds != nil || idleSeconds != nil }
}

/// The plan day as "yyyy-MM-dd". A day runs 4am to 4am, the same as Stats, so a late night belongs to the day before.
func today(_ now: Date = Date()) -> String { DateFormatter.ymd.string(from: Stats.day(of: now)) }
func tomorrowDate(_ now: Date = Date()) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: Stats.day(of: now)) ?? now }

func logTimestamp(_ d: Date = Date()) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
}

func appendLog(_ ev: [String: Any]) {
    var e = ev
    if e["ts"] == nil { e["ts"] = logTimestamp() }
    guard let d = try? JSONSerialization.data(withJSONObject: e), var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else { try? line.write(to: Paths.log, atomically: true, encoding: .utf8) }
}

// Small persistent state: the running session, the day the morning screen was passed, when lockin last quit mid-session.
struct AppState: Codable {
    var active: ActiveBlock?
    var plan_shown: String?
    var quit_at: Double?
    static func load() -> AppState {
        guard let d = try? Data(contentsOf: Paths.state), let s = try? JSONDecoder().decode(AppState.self, from: d) else { return AppState() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Paths.state) } }
}

func fmtTime(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded(.up)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// Runs the Python helper (plan text, recap text, the AI planner) with an environment Claude can log in from.
func runCoach(_ args: [String], input: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [Paths.coach.path] + args
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let user = NSUserName()
    // PATH covers the usual install spots of the `claude` CLI (npm global, Homebrew, the native installer).
    var env = ["PATH": "\(home)/.local/bin:\(home)/.claude/local:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
               "HOME": home, "USER": user, "LOGNAME": user, "LANG": "en_US.UTF-8", "TERM": "xterm",
               "FOCUS_DATA": Paths.dir.path, "FOCUS_CALEVENTS": Paths.calevents.path, "FOCUS_TODAY": today(),
               "PYTHONDONTWRITEBYTECODE": "1"]   // never write __pycache__ into the signed app bundle
    if ["todos", "test", "questions", "breakdown", "tiny"].contains(args.first ?? ""), let key = Keychain.get() { env["FOCUS_AI_KEY"] = key }  // only calls that reach the AI
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    let inp = Pipe(); p.standardInput = inp
    do { try p.run() } catch { return "" }
    if let input { inp.fileHandleForWriting.write(input.data(using: .utf8)!) }
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Soonest start today ("HH:MM") for a session this long: after now, around calendar events and anything already
/// scheduled. "" if nothing fits before the end of the day. Runs the helper script, so call it off the main thread.
func soonestSlot(minutes: Int, skip: String? = nil) -> String {
    let out = runCoach(["slot", String(minutes)] + (skip.map { [$0] } ?? []))
    let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    return obj?["start"] as? String ?? ""
}

extension DateFormatter {
    static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
}

func parseHHMM(_ s: String, on day: Date = Date()) -> Date? {
    let p = s.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
    return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: day)
}
func hhmm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
/// "9:30 AM" for "09:30" ("" for no time).
func clockLabel(_ s: String?) -> String {
    guard let s, let d = parseHHMM(s) else { return "" }
    return d.formatted(date: .omitted, time: .shortened)
}
