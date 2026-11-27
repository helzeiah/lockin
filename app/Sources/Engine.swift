import AppKit
import Combine
import Foundation

enum CardAction: Hashable {
    case dismiss, backToIt, snoozeDrift, startBreak, startNext, startTen, openPlanner, stop, confirmStop, addFive, startGoal, openStats
    case planTomorrow
    case startTodo(String), snoozeTodo(String), equipSkin(String)
    case lockInEvent(String), skipEvent(String), neverEvent(String)
    case planListTask(String), planListTaskTomorrow(String), startListTask(String)   // a to-do list task, by id
}

/// A short message that drops out of the notch for a few seconds (check-ins). Never steals focus, never needs a click.
struct Flash: Equatable {
    let id = UUID()
    var text: String
    var icon: String
    var tint: String = "green"
}

/// What the cover is over: a distracting site or app, an app outside the session, or (outside sessions, before today
/// counts) a distraction you haven't earned yet.
struct Blocked: Equatable {
    enum Kind { case site, app, strict, earn }
    var site: String
    var app: String
    var frame: NSRect?
    var kind: Kind
    var strict: Bool { kind == .strict }
}

struct CardLine: Hashable { var text: String; var trailing: String = ""; var deadline = false; var bullet = true; var time = ""; var calendar = false }
struct CardButton: Hashable { var label: String; var action: CardAction; var primary = false }
struct Card: Identifiable, Equatable {
    let id = UUID()
    var icon: String           // SF Symbol name
    var tint: String = "white" // white | green | orange | red | blue
    var title: String
    var subtitle: String = ""
    var lines: [CardLine] = []
    var buttons: [CardButton] = []
    var autoClose: Double? = nil
    var countdown: Date? = nil       // shows "in 12s" and runs onTimeout when it reaches zero
    var onTimeout: CardAction? = nil
    var xp: XPGain? = nil            // after a session: the XP bar fills from before to after
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var cfg: Config
    @Published var block: ActiveBlock?
    @Published var now = Date()
    @Published var drifting = false
    @Published var card: Card?
    /// The stats drop-down under the notch.
    @Published var statsShown = false
    @Published var plannerTab: PlannerTab = .plan
    @Published var planDay: PlanDay = .today
    @Published var flash: Flash?
    private var flashTask: DispatchWorkItem?
    private var checkedIn: (half: Double, last: Double) = (0, 0)   // the session (by start time) each check-in already ran for
    @Published var todos: [Todo] = []
    @Published var tomorrow: [Todo] = []
    @Published var chat: [ChatMsg] = []
    @Published var backlog: [Todo] = []
    @Published var todayShape: DayShape?       // today's breaks and finish time, once you've answered
    @Published var tomorrowShape: DayShape?
    @Published var listTasks: [ListTask] = []  // the running to-do list
    @Published var askingAI: String?           // the list task the AI is thinking up questions for
    @Published var listError: String?
    @Published var events: [CalEvent] = []
    private var lastDay = today()
    @Published var planning = false
    @Published var planError: String?
    /// What the last typed edit did, shown under the plan box for a few seconds ("Done: LeetCode · Essay → 3:00 PM").
    @Published var planNote: String?
    private var planNoteTask: DispatchWorkItem?
    @Published var blocked: Blocked? = nil
    @Published var gateShown = false
    /// Focused minutes today (finished sessions), refreshed when a session ends and once a minute.
    @Published var todayMinutes = 0
    /// The app you were last in, other than lockin itself (the menu's popover makes lockin the front app).
    @Published var lastExternalApp = ""

    private var timers: [Timer] = []
    private var driftSince: Date?
    private var lastNudge: Date?
    private var snoozeUntil = Date.distantPast
    private var snoozedSites: [String: Date] = [:]
    private var lastOnTask: (app: String, url: String)?
    private var lastIdleNudge = Date().addingTimeInterval(-30 * 60)
    private var lastBlockEnd = Date.distantPast
    @Published private(set) var coverShownAt = Date.distantPast
    private var lastCoverSound = Date.distantPast
    private var closeTask: DispatchWorkItem?
    private var checking = false
    private var askedEvents = Set<String>()
    private var promptedTodos = Set<String>()
    private var minuteCount = 0
    private var lastEval: Date?
    /// Real work needs a key press, click or scroll this recently (reading and thinking get some slack).
    static let activeWindow: Double = 90

    /// The running session's rules: only its apps (plus always-fine ones), its task rule's sites and Claude folders.
    var preset: Preset? {
        guard let b = block, b.kind == "focus" else { return nil }
        let rule = (b.rule ?? (b.apps == nil ? b.name : nil)).flatMap { r in cfg.blocks.first { $0.name == r } }
        let apps = b.apps ?? rule?.apps ?? cfg.lockin_apps ?? []
        let terminal = apps.contains { Detect.terminals.contains($0) }
        var p = rule ?? Preset(name: b.name, minutes: b.minutes)
        p.apps = apps
        p.strict = true
        p.terminal_ok = terminal
        p.any_claude = (rule?.projects ?? []).isEmpty ? terminal : false   // no folder rule: any Claude session counts
        return p
    }
    var isBreak: Bool { block?.kind == "break" }
    var remaining: Double { (block?.ends ?? 0) - now.timeIntervalSince1970 }
    var progress: Double {
        guard let b = block else { return 0 }
        return min(1, max(0, 1 - remaining / Double(b.minutes * 60)))
    }
    var nextTodo: Todo? { todos.first { !$0.isDone } }
    var goal: Int { cfg.stats_goal ?? 25 }
    var todayCounts: Bool { todayMinutes >= goal }

    // Passes: "Give me 5 min" waits a few seconds (friction), runs out, and doesn't exist in Locked mode.
    static let snoozesPerBlock = 2
    static let snoozeWait = 10.0
    var locked: Bool { cfg.locked }
    /// Earning free time: outside sessions, distractions stay covered until today counts.
    var earning: Bool { (cfg.earn_free_time ?? true) && !todayCounts && !SetupWindow.needed }
    private var freePassesKey: String { "freePasses-" + today() }
    var freePassesUsed: Int { UserDefaults.standard.integer(forKey: freePassesKey) }
    var passesLeft: Int {
        if locked { return 0 }
        if blocked?.kind == .earn { return max(0, (cfg.free_passes ?? 3) - freePassesUsed) }
        return max(0, Engine.snoozesPerBlock - (block?.snoozes ?? 0))
    }
    /// Seconds until a pass (or "Add to this session") can be clicked on the current cover.
    var snoozeWaitLeft: Int { max(0, Int((Engine.snoozeWait - now.timeIntervalSince(coverShownAt)).rounded(.up))) }
    /// An app outside the session that isn't a distraction can be added to it (it's logged).
    var canAddBlockedApp: Bool {
        guard let b = blocked, b.kind == .strict, block?.kind == "focus" else { return false }
        return anyIn(b.app, cfg.distractions.apps) == nil
    }

    init() {
        cfg = Config.load() ?? .empty
        reloadTodos()
        restoreSession()
        todayMinutes = finishedToday()
    }

    /// Picks the running session back up after a restart. One that ran out while lockin was quit counts up to the quit.
    private func restoreSession() {
        var s = AppState.load()
        defer { s.quit_at = nil; s.save() }
        guard let a = s.active else { return }
        let t = Date().timeIntervalSince1970
        if a.ends > t { block = a; return }
        s.active = nil
        guard a.kind == "focus", let q = s.quit_at else { return }
        let end = min(q, a.ends)
        let elapsed = max(0, Int((end - a.started) / 60))
        var entry: [String: Any] = ["type": "block_end", "ts": logTimestamp(), "name": a.name, "task": a.task ?? "", "completed": false, "how": "quit",
                                    "planned_min": a.minutes, "elapsed_min": elapsed,
                                    "focused_min": a.tracked ? min(elapsed, a.countedMinutes) : max(0, elapsed - Int(a.offSeconds / 60)),
                                    "active_min": Int(((a.activeSeconds ?? 0) / 60).rounded()), "offline_min": Int(((a.offlineSeconds ?? 0) / 60).rounded()),
                                    "idle_min": Int(((a.idleSeconds ?? 0) / 60).rounded()), "apps": a.apps ?? []]
        entry["sig"] = Integrity.sign(entry)
        appendLog(entry)
    }

    func start() {
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.tick() } },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.check() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.minute() } },
        ]
        let nc = NSWorkspace.shared.notificationCenter
        lastExternalApp = Detect.frontApp() == selfAppName ? "" : Detect.frontApp()
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let name = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? ""
            Task { @MainActor in if !name.isEmpty, name != selfAppName { self.lastExternalApp = name } }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in self.morningCheck() } }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in self.morningCheck() }
        }
        refreshEvents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.morningCheck() }
    }

    func reloadConfig() { if let c = Config.load() { cfg = c; statsCache = nil } }
    func reloadTodos() {
        let d = TodoDoc.load()      // rolls yesterday's leftovers into the backlog, tomorrow into today
        todos = d.items
        tomorrow = d.tomorrow ?? []
        chat = d.chat ?? []
        backlog = d.backlog ?? []
        todayShape = d.shape
        tomorrowShape = d.tomorrow_shape
        syncListFromPlan(d)
    }
    func list(_ day: PlanDay) -> [Todo] { day == .today ? todos : tomorrow }
    func shape(_ day: PlanDay) -> DayShape? { day == .today ? todayShape : tomorrowShape }

    func refreshEvents() {
        guard (cfg.calendar_mode ?? "ask") != "off" else { events = []; return }
        DispatchQueue.global(qos: .utility).async {
            let ev = CalendarFeed.events()
            Task { @MainActor in self.events = ev }
        }
    }

    // MARK: planning (works without any AI)

    /// Adds what you typed ("leetcode 45, co-op 90 at 2pm") to today or tomorrow. Today, tasks without a time get the
    /// soonest open slot; each one's apps come from its words.
    func addParsed(_ text: String, day: PlanDay) { addTasks(PlanParser.parse(text), day: day) }

    func addTasks(_ parsed: [ParsedTask], day: PlanDay) {
        guard !parsed.isEmpty else { return }
        let cfg = self.cfg
        planning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let history = TaskMatch.history()
            for p in parsed {
                let minutes = p.minutes ?? 45
                let start = p.start ?? (day == .today ? soonestSlot(minutes: minutes) : "")
                let match = TaskMatch.apps(for: p.task, cfg: cfg, history: history)
                DispatchQueue.main.sync {
                    self.addTodo(task: p.task, minutes: minutes, start: start, day: day, apps: match.apps, rule: match.rule, pinned: p.start != nil)
                }
            }
            Task { @MainActor in self.planning = false }
        }
    }

    /// What you typed into the plan box, without any AI: new tasks get a time and their apps, and edits change the
    /// session they mean ("done leetcode", "essay at 3pm", "push emails to tomorrow", "make essay 30 min", "free at 8").
    func applyTyped(_ text: String, day: PlanDay) {
        let commands = PlanParser.commands(text)
        guard !commands.isEmpty else { return }
        var notes: [String] = [], adds: [ParsedTask] = []
        func missing(_ q: String) { notes.append("Nothing on the plan matches \"\(q)\"") }
        for c in commands {
            switch c {
            case .add(let p):
                if let start = p.start, p.minutes == nil, let t = match(p.task, in: list(day), open: true) {   // "essay at 3pm": move it
                    let s = adjusted(start, day); updateTodo(t.id, start: s); notes.append("\(t.task) → \(clockLabel(s))")
                } else { adds.append(p) }
            case .done(let q):
                if let t = match(q, in: list(day), open: true) { setDone(t.id, true); notes.append("Done: \(t.task)") } else { missing(q) }
            case .remove(let q):
                if let t = match(q, in: list(day), open: false) { deleteTodo(t.id); notes.append("Removed \(t.task)") } else { missing(q) }
            case .move(let q, let start):
                if let t = match(q, in: list(day), open: true) {
                    let s = adjusted(start, day); updateTodo(t.id, start: s); notes.append("\(t.task) → \(clockLabel(s))")
                } else { missing(q) }
            case .tomorrow(let q):
                if let t = match(q, in: todos, open: true) { move(t.id, to: .tomorrow); notes.append("\(t.task) → tomorrow") } else { missing(q) }
            case .resize(let q, let minutes):
                if let t = match(q, in: list(day), open: true) { updateTodo(t.id, minutes: minutes); notes.append("\(t.task): \(minutes) min") } else { missing(q) }
            case .startFrom(let start):
                let s = adjusted(start, day), n = reflow(from: s, day: day)
                notes.append("Re-timed \(n) session\(n == 1 ? "" : "s") from \(clockLabel(s))")
            }
        }
        if !adds.isEmpty { addTasks(adds, day: day); notes.append("Added \(adds.count) session\(adds.count == 1 ? "" : "s")") }
        showPlanNote(notes.joined(separator: " · "))
    }

    func showPlanNote(_ text: String) {
        planNoteTask?.cancel()
        planNote = text
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.planNote = nil } }
        planNoteTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    /// The session a typed edit means: most shared words (by letters), and a big bonus if the text is inside its name.
    func match(_ query: String, in list: [Todo], open: Bool) -> Todo? {
        let qw = TaskMatch.words(query), ql = query.lowercased()
        var best: (todo: Todo, score: Int)?
        for t in list where !open || !t.isDone {
            var score = TaskMatch.words(t.task).intersection(qw).reduce(0) { $0 + $1.count }
            if !ql.isEmpty, t.task.lowercased().contains(ql) { score += 10 }
            if score >= 3, score > (best?.score ?? 0) { best = (t, score) }
        }
        return best?.todo
    }

    /// "free at 8" said at 6pm means 8pm: a morning time that's already past today becomes the evening one.
    func adjusted(_ start: String, _ day: PlanDay) -> String {
        guard day == .today, let d = parseHHMM(start), d < Date(), Calendar.current.component(.hour, from: d) < 12,
              let pm = Calendar.current.date(byAdding: .hour, value: 12, to: d), pm > Date() else { return start }
        return hhmm(pm)
    }

    /// Re-times everything not done yet, in order, starting at `start` with 5-minute breaks. Returns how many moved.
    @discardableResult func reflow(from start: String, day: PlanDay) -> Int {
        guard var t0 = parseHHMM(start, on: day == .today ? Date() : tomorrowDate()) else { return 0 }
        var d = TodoDoc.load(), n = 0
        d.edit(day) { list in
            for i in list.indices where !list[i].isDone {
                list[i].start = hhmm(t0); t0 = t0.addingTimeInterval(Double(list[i].left + 5) * 60); n += 1
            }
        }
        d.save(); reloadTodos()
        return n
    }

    /// The plan follows the day (see TodoDoc.retimed): today's open sessions re-timed from `from` around the calendar
    /// and your breaks, ending by your finish time. Returns how many moved. Today not between midnight and 4am, when
    /// the clock and the plan day disagree. Tomorrow's sessions only move out of the way of its breaks and finish time.
    @discardableResult func shiftPlan(from: Date, freed: (start: Date, end: Date)? = nil, last: String? = nil, day: PlanDay = .today) -> Int {
        let now = day == .today ? Date() : tomorrowDate()
        if day == .today { guard Calendar.current.isDate(Stats.day(of: now), inSameDayAs: now) else { return 0 } }
        var d = TodoDoc.load()
        let shape = d.shape(day)
        let busy = (day == .today ? events.filter { !$0.allDay }.map { ($0.start, $0.end) } : []) + (shape?.busy(on: now) ?? [])
        let end = parseHHMM(shape?.finish ?? cfg.day_end ?? "23:30", on: now) ?? now
        let list = d.list(day)
        let new = TodoDoc.retimed(list, from: from, busy: busy, dayEnd: end, now: now, freed: freed,
                                  keep: day == .today ? block?.todoId : nil, last: last)
        let moved = zip(list, new).filter { $0.start != $1.start }.count
        guard moved > 0 else { return 0 }
        d.edit(day) { $0 = new }; d.save(); reloadTodos()
        return moved
    }

    /// Your answer to "when are your breaks, and when do you finish?" for a day: saved with the plan, remembered as the
    /// starting point next time, and the plan moves to fit it.
    func setShape(_ shape: DayShape, day: PlanDay) {
        var d = TodoDoc.load()
        if day == .today { d.shape = shape } else { d.tomorrow_shape = shape }
        d.save(); reloadTodos()
        DayShape.last = shape
        let timed = Set(list(day).filter { !$0.isDone && !($0.start ?? "").isEmpty }.map(\.id))
        let n = shiftPlan(from: day == .today ? planAnchor : tomorrowDate(), day: day)
        let dropped = list(day).filter { timed.contains($0.id) && ($0.start ?? "").isEmpty }.count
        appendLog(["type": "day_shape", "day": day.rawValue, "breaks": shape.breaks.map { "\($0.start)+\($0.minutes)" }, "finish": shape.finish ?? ""])
        if dropped > 0 { showPlanNote("\(dropped) session\(dropped == 1 ? "" : "s") won't fit before \(clockLabel(shape.finish ?? cfg.day_end ?? "23:30")). Shorten or move \(dropped == 1 ? "it" : "them")") }
        else if n > 0 { showPlanNote("Moved \(n) session\(n == 1 ? "" : "s") around your day") }
    }
    /// When the next session can start: after the running one (and a break), else now.
    var planAnchor: Date {
        guard let b = block else { return Date() }
        return Date(timeIntervalSince1970: b.ends + (b.kind == "focus" ? 300 : 0))
    }
    /// The slot a to-do on today's plan was set for.
    func slot(of id: String) -> (start: Date, end: Date)? {
        guard let t = todos.first(where: { $0.id == id }), let a = parseHHMM(t.start ?? "") else { return nil }
        return (a, a.addingTimeInterval(Double(t.left) * 60))
    }

    func addTodo(task: String, minutes: Int, start: String, day: PlanDay = .today, apps: [String]? = nil, rule: String? = nil, pinned: Bool = false) {
        var d = TodoDoc.load()
        d.edit(day) { $0.append(Todo(id: Todo.newId(), task: task, block: rule ?? "", minutes: minutes, start: start, apps: apps,
                                     pinned: pinned && !start.isEmpty ? true : nil)) }
        d.save(); reloadTodos()
    }

    /// Edits a to-do wherever it is (today, tomorrow or the backlog). Only the fields passed change. A new time is one
    /// you chose, so the plan flows around it (pinned) until it goes by.
    func updateTodo(_ id: String, task: String? = nil, start: String? = nil, minutes: Int? = nil, apps: [String]? = nil) {
        var d = TodoDoc.load()
        func apply(_ t: inout Todo) {
            if let task { t.task = task }
            if let start, start != t.start { t.start = start; t.pinned = start.isEmpty ? nil : true }
            if let minutes { t.minutes = minutes }
            if let apps { t.apps = apps }
        }
        let onToday = d.items.contains { $0.id == id }
        if let i = d.items.firstIndex(where: { $0.id == id }) { apply(&d.items[i]) }
        else if let i = d.tomorrow?.firstIndex(where: { $0.id == id }) { apply(&d.tomorrow![i]) }
        else if let i = d.backlog?.firstIndex(where: { $0.id == id }) { apply(&d.backlog![i]) }
        else { return }
        d.sortItems(); d.save(); reloadTodos()
        if onToday, start != nil || minutes != nil { shiftPlan(from: planAnchor) }   // anything it now overlaps moves out of the way
        if var b = self.block, b.todoId == id {      // edited while it's running
            if let task { b.task = task }
            if let apps { b.apps = apps }
            self.block = b; persist()
        }
    }
    func deleteTodo(_ id: String) {
        var d = TodoDoc.load()
        d.items.removeAll { $0.id == id }; d.tomorrow?.removeAll { $0.id == id }
        d.save(); reloadTodos()
    }
    /// Moves a to-do between today and tomorrow (keeping its time).
    func move(_ id: String, to day: PlanDay) {
        var d = TodoDoc.load()
        guard let t = (d.items + (d.tomorrow ?? [])).first(where: { $0.id == id }) else { return }
        d.items.removeAll { $0.id == id }; d.tomorrow?.removeAll { $0.id == id }
        d.edit(day) { $0.append(t) }
        d.save(); reloadTodos()
    }
    func addFromBacklog(_ t: Todo) {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = soonestSlot(minutes: t.minutes)
            Task { @MainActor in
                var d = TodoDoc.load()
                d.backlog?.removeAll { $0.id == t.id }
                var item = t; item.from = nil; item.start = start; item.done = false; item.why = ""
                d.items.append(item); d.sortItems(); d.save(); self.reloadTodos()
            }
        }
    }
    func dropFromBacklog(_ id: String) { var d = TodoDoc.load(); d.backlog?.removeAll { $0.id == id }; d.save(); reloadTodos() }
    func clearBacklog() { var d = TodoDoc.load(); d.backlog = []; d.save(); reloadTodos() }
    func clearDay(_ day: PlanDay = .today) {
        var d = TodoDoc.load()
        if day == .today { d.items = []; d.chat = [] } else { d.tomorrow = [] }
        d.save(); reloadTodos()
    }

    // MARK: repeating sessions

    var routines: [Routine] { cfg.routines ?? [] }
    func routine(for t: Todo) -> Routine? { t.isRoutine ? routines.first { $0.id == t.ref } : nil }

    /// Makes a to-do repeat on these days (1 = Sunday), or stop repeating with nil/empty.
    func setRepeat(_ t: Todo, days: [Int]?) {
        var list = routines
        var d = TodoDoc.load()
        func mark(_ source: String?, _ ref: String?) {
            if let i = d.items.firstIndex(where: { $0.id == t.id }) { d.items[i].source = source; d.items[i].ref = ref }
            if let i = d.tomorrow?.firstIndex(where: { $0.id == t.id }) { d.tomorrow![i].source = source; d.tomorrow![i].ref = ref }
        }
        if let days, !days.isEmpty {
            let id = t.isRoutine ? (t.ref ?? Todo.newId()) : Todo.newId()
            let r = Routine(id: id, task: t.task, minutes: t.minutes, start: (t.start ?? "").isEmpty ? "09:00" : t.start!, days: days.sorted(), apps: t.apps)
            if let i = list.firstIndex(where: { $0.id == id }) { list[i] = r } else { list.append(r) }
            mark("routine", id)
        } else if let ref = t.ref {
            list.removeAll { $0.id == ref }
            mark(nil, nil)
        }
        d.save()
        saveRoutines(list)
        reloadTodos()
    }
    func deleteRoutine(_ id: String) { saveRoutines(routines.filter { $0.id != id }) }
    private func saveRoutines(_ list: [Routine]) {
        let arr = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(list))) ?? []
        editConfig { $0["routines"] = arr }
        reloadConfig()
    }

    // MARK: sessions

    /// Starts a session. Its apps come from the to-do, else a task rule, else what you used last time, else your
    /// lock-in apps. Everything else gets covered until it ends.
    func startSession(task: String?, minutes: Int, apps: [String]? = nil, rule: String? = nil, todoId: String? = nil) {
        if block?.kind == "focus" { stopBlock(completed: false, silent: true, how: "replaced") }
        let m = min(max(minutes, 1), 480)
        var allowed = apps
        var ruleName = rule
        if allowed == nil, let rule, let r = cfg.blocks.first(where: { $0.name == rule }), !(r.apps ?? []).isEmpty { allowed = r.apps }
        if allowed == nil, let task, !task.isEmpty {
            let match = TaskMatch.apps(for: task, cfg: cfg)
            allowed = match.apps; ruleName = ruleName ?? match.rule
        }
        let apps = allowed ?? cfg.lockin_apps ?? []
        let t = Date().timeIntervalSince1970
        block = ActiveBlock(kind: "focus", name: ruleName ?? task ?? "Focus", task: task, todoId: todoId, started: t,
                            ends: t + Double(m * 60), minutes: m, offSeconds: 0, apps: apps, rule: ruleName)
        driftSince = nil; lastNudge = nil; snoozeUntil = .distantPast; snoozedSites = [:]; lastOnTask = nil; drifting = false; blocked = nil
        block?.activeSeconds = 0; block?.offlineSeconds = 0; block?.idleSeconds = 0; lastEval = nil
        appendLog(["type": "block_start", "name": block!.name, "minutes": m, "task": task ?? "", "apps": apps])
        persist()
        if let todoId, todos.contains(where: { $0.id == todoId }) {   // started early or late: the rest of today moves to fit
            let planned = slot(of: todoId)
            var d = TodoDoc.load()
            if let i = d.items.firstIndex(where: { $0.id == todoId }) { d.items[i].start = hhmm(Date()); d.items[i].pinned = nil; d.save() }
            reloadTodos()
            shiftPlan(from: planAnchor, freed: planned)
        }
        if AppState.load().plan_shown != today() { passGate(how: "session") }   // starting work counts as starting the day
        let names = apps.prefix(3).joined(separator: ", ") + (apps.count > 3 ? " +\(apps.count - 3)" : "")
        show(Card(icon: "lock.fill", tint: "green", title: task ?? "Locked in",
                  subtitle: "\(m) min · " + (apps.isEmpty ? "only your always-fine apps" : names)), close: 2.6)
        play("Tink", volume: 0.35)
    }

    func startTodo(_ t: Todo, minutes: Int? = nil) {
        startSession(task: t.task, minutes: minutes ?? t.left, apps: t.apps, rule: t.block.isEmpty ? nil : t.block,
                     todoId: minutes == nil ? t.id : nil)
    }
    /// No task, just a length: your lock-in apps only.
    func startQuick(minutes: Int) { startSession(task: nil, minutes: minutes, apps: cfg.lockin_apps ?? []) }
    /// lockin://start?block=Name: a task rule by name (kept from v1).
    func startBlock(_ p: Preset, minutes: Int? = nil, task: String? = nil) {
        startSession(task: task ?? p.name, minutes: minutes ?? p.minutes, apps: (p.apps ?? []).isEmpty ? nil : p.apps, rule: p.name)
    }
    func presetFor(_ name: String) -> Preset? {
        let n = name.lowercased()
        guard !n.isEmpty else { return nil }
        return cfg.blocks.first { $0.name.lowercased() == n } ?? TaskMatch.rule(for: name, in: cfg.blocks)
    }

    func startBreak() {
        let m = cfg.break_minutes ?? 5, t = Date().timeIntervalSince1970
        block = ActiveBlock(kind: "break", name: "Break", task: nil, todoId: nil, started: t, ends: t + Double(m * 60), minutes: m, offSeconds: 0)
        blocked = nil; persist()
    }

    func addFive() { if var b = block { b.ends += 300; b.minutes += 5; block = b; persist() } }

    /// Ends the session. `completed` = the timer ran out; anything else is ending early (it still counts its minutes).
    func stopBlock(completed: Bool, silent: Bool = false, how: String = "stopped") {
        guard let b = block else { return }
        block = nil; blocked = nil; drifting = false; lastBlockEnd = Date(); statsCache = nil; persist()
        if b.kind == "break" {
            if !silent {
                let n = nextTodo
                show(Card(icon: "cup.and.saucer.fill", tint: "orange", title: "Break's over",
                          subtitle: n.map { "Next: \($0.task)" } ?? "Ready for another session?",
                          buttons: [CardButton(label: "Not yet", action: .dismiss)] + (n != nil ? [CardButton(label: "Lock in", action: .startNext, primary: true)] : [CardButton(label: "Plan", action: .openPlanner, primary: true)])))
            }
            return
        }
        let elapsed = Int((Date().timeIntervalSince1970 - b.started) / 60)
        // Only real work counts: active minutes, plus away time on offline-ok tasks. (Old sessions: elapsed minus off-task.)
        let focused = b.tracked ? min(elapsed, b.countedMinutes) : max(0, elapsed - Int(b.offSeconds / 60))
        let idleMin = Int(((b.idleSeconds ?? 0) / 60).rounded())
        let activeMin = Int(((b.activeSeconds ?? 0) / 60).rounded()), offlineMin = Int(((b.offlineSeconds ?? 0) / 60).rounded())
        let rBefore = Rewards.load(goal: goal)   // read before this session is in the log
        var entry: [String: Any] = ["type": "block_end", "ts": logTimestamp(), "name": b.name, "task": b.task ?? "", "completed": completed,
                                    "how": completed ? "timer" : how, "planned_min": b.minutes, "elapsed_min": elapsed, "focused_min": focused,
                                    "active_min": activeMin, "offline_min": offlineMin, "idle_min": idleMin, "apps": b.apps ?? []]
        entry["sig"] = Integrity.sign(entry)
        appendLog(entry)
        if let id = b.todoId {
            let ran = slot(of: id).map { (start: $0.start, end: Date(timeIntervalSince1970: b.ends)) }
            if completed { setDone(id, true, shift: false) }
            else { addSpent(id, Int(((Date().timeIntervalSince1970 - b.started) / 60).rounded())) }   // resume with what's left
            // The rest of today moves to fit, after a break; what's left of a session ended early goes after the others.
            shiftPlan(from: Date().addingTimeInterval(300), freed: ran, last: completed ? nil : id)
        }
        let before = todayMinutes
        let st = stats()
        let rAfter = Rewards.load(goal: goal)
        todayMinutes = st.todayMinutes
        guard !silent else { return }
        let xp = xpGain(rBefore.xp, rAfter.xp, worked: activeMin + offlineMin / 2, planned: b.minutes, completed: completed)
        let hitGoal = st.todayMinutes >= goal && before < goal   // this session made today count
        let breakButtons = [CardButton(label: "Skip break", action: .startNext), CardButton(label: "Break \(cfg.break_minutes ?? 5) min", action: .startBreak, primary: true)]
        Skin.noteLevel(rAfter.level)
        if rAfter.level > rBefore.level {   // the card plays the fanfare when its bar crosses into the new level
            let skin = Skin.all.last { $0.level > rBefore.level && $0.level <= rAfter.level }
            show(Card(icon: "emblem:\(rAfter.level)", tint: "green", title: "Level \(rAfter.level) · \(rAfter.title)",
                      subtitle: skin.map { "Unlocked the \($0.name) skin" } ?? "",
                      buttons: (skin.map { [CardButton(label: "Equip \($0.name)", action: .equipSkin($0.id))] } ?? [CardButton(label: "See rewards", action: .openStats)])
                        + breakButtons, xp: xp))
            return
        }
        if let b = rAfter.badges.first(where: { nb in nb.earned != nil && rBefore.badges.contains { $0.id == nb.id && $0.earned == nil } }) {
            play("Hero", volume: 0.5)
            show(Card(icon: b.icon, tint: "orange", title: "Badge: \(b.name)", subtitle: b.how,
                      buttons: [CardButton(label: "See badges", action: .openStats)] + breakButtons, xp: xp))
            return
        }
        if completed {
            if hitGoal, let m = milestone(st.streak) {
                play("Hero", volume: 0.55)
                show(Card(icon: "flame.fill", tint: "orange", title: "\(st.streak)-day streak", subtitle: m, buttons: breakButtons, xp: xp))
                return
            }
            if perfectDay() {
                play("Hero", volume: 0.5)
                show(Card(icon: "star.fill", tint: "orange", title: "Perfect day", subtitle: "Every session you planned, done · \(fmtMinutes(st.todayMinutes)) focused",
                          buttons: [CardButton(label: "Plan tomorrow", action: .planTomorrow), CardButton(label: "Nice", action: .dismiss, primary: true)], xp: xp))
                return
            }
            play(hitGoal ? "Hero" : "Glass", volume: hitGoal ? 0.5 : 0.45)
            let idleNote = idleMin >= 2 ? " · \(idleMin) idle min didn't count" : ""
            let line = hitGoal ? "Today counts · \(st.streak)-day streak" : "\(fmtMinutes(st.todayMinutes)) today" + (st.todayMinutes < goal ? " · \(goal - st.todayMinutes) min to make today count" : "")
            show(Card(icon: hitGoal ? "flame.fill" : "checkmark.circle.fill", tint: hitGoal ? "orange" : "green",
                      title: hitGoal ? "Today counts. \(b.task ?? "Session") done" : (b.task ?? "Session done"),
                      subtitle: "\(focused) min focused\(idleNote) · \(line)", buttons: breakButtons, xp: xp))
        } else if focused >= 5 {
            show(Card(icon: "stop.circle.fill", tint: "white", title: "Ended early",
                      subtitle: "\(focused) of \(b.minutes) min. The minutes still count · \(fmtMinutes(st.todayMinutes)) today", xp: xp), close: xp == nil ? 3.5 : 6)
        } else {
            show(Card(icon: "stop.circle.fill", tint: "white", title: "Ended early", subtitle: "Restarting is the skill. Try 10 minutes next.", xp: xp),
                 close: xp == nil ? 3 : 5.5)
        }
    }

    /// The XP a session earned and where it came from (mirrors Rewards.load: worked minutes, +10 for finishing, the
    /// rest is the bonus for making today count). Nil when it earned nothing.
    private func xpGain(_ before: Int, _ after: Int, worked: Int, planned: Int, completed: Bool) -> XPGain? {
        guard after > before else { return nil }
        let finished = completed && worked >= max(5, planned / 2)
        var parts = ["\(worked) min on task"]
        if finished { parts.append("+10 finished") }
        let bonus = after - before - worked - (finished ? 10 : 0)
        if bonus > 0 { parts.append("+\(bonus) today counts") }
        return XPGain(from: before, to: after, parts: parts)
    }

    /// A streak milestone worth its own card (once per run of the streak), with its line.
    private func milestone(_ streak: Int) -> String? {
        let lines = [3: "Three days in a row. It's turning into a habit.", 7: "A full week. Keep it going.",
                     14: "Two weeks straight.", 30: "A month of showing up.", 50: "Fifty days.", 100: "A hundred days in a row.",
                     200: "Two hundred days.", 365: "A whole year."]
        guard let line = lines[streak], UserDefaults.standard.integer(forKey: "milestone-" + today()) != streak else { return nil }
        UserDefaults.standard.set(streak, forKey: "milestone-" + today())
        return line
    }
    /// Every session planned today is done (two or more), once a day.
    private func perfectDay() -> Bool {
        let key = "perfect-" + today()
        guard todos.count >= 2, todos.allSatisfy(\.isDone), !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)
        appendLog(["type": "perfect_day", "sessions": todos.count])
        return true
    }

    private func persist() { var s = AppState.load(); s.active = block; s.save() }

    /// lockin quit while a session runs: noted (it shows in the recap), and the session picks back up on relaunch.
    func noteQuit() {
        guard let b = block, b.kind == "focus" else { return }
        var s = AppState.load(); s.quit_at = Date().timeIntervalSince1970; s.active = b; s.save()
        appendLog(["type": "quit_during_session", "name": b.name, "task": b.task ?? ""])
    }

    // MARK: the morning screen

    func passGate(how: String, reason: String? = nil) {
        var s = AppState.load(); s.plan_shown = today(); s.save()
        var ev: [String: Any] = ["type": how == "skip" ? "gate_skipped" : "gate_passed", "how": how, "planned": todos.filter { !$0.isDone }.count]
        if let reason { ev["reason"] = String(reason.prefix(300)) }
        appendLog(ev)
    }

    // MARK: cards

    func show(_ c: Card, close: Double? = nil) {
        closeTask?.cancel()
        statsShown = false
        card = c
        if let close = close ?? c.autoClose {
            let w = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.card?.id == c.id { self?.card = nil } } }
            closeTask = w
            DispatchQueue.main.asyncAfter(deadline: .now() + close, execute: w)
        }
    }

    func perform(_ a: CardAction) {
        card = nil
        switch a {
        case .dismiss, .backToIt: break
        case .snoozeDrift: snoozeUntil = Date().addingTimeInterval(300); driftSince = nil; lastNudge = nil; drifting = false
        case .startBreak: startBreak()
        case .startNext: if let t = nextTodo { startTodo(t) } else { Planner.shared.open() }
        case .startTen: if let t = nextTodo { startTodo(t, minutes: 10) }
        case .openPlanner: Planner.shared.open()
        case .planTomorrow: planDay = .tomorrow; Planner.shared.open(day: .tomorrow)
        case .stop: stopBlock(completed: false)
        case .confirmStop:
            show(Card(icon: "exclamationmark.lock.fill", tint: "red", title: "End this session early?",
                      subtitle: "It counts as ended early in your stats. \(fmtTime(remaining)) left.",
                      buttons: [CardButton(label: "End it", action: .stop), CardButton(label: "Keep going", action: .dismiss, primary: true)]), close: 10)
        case .addFive: addFive()
        case .openStats: Planner.shared.open(tab: .stats)
        case .startGoal:
            let need = max(10, goal - todayMinutes)
            if let t = nextTodo { startTodo(t, minutes: max(need, 25)) } else { startQuick(minutes: max(need, 25)) }
        case .startTodo(let id): if let t = todos.first(where: { $0.id == id }) { startTodo(t) }
        case .snoozeTodo(let id):
            if let t = todos.first(where: { $0.id == id }) {
                appendLog(["type": "postponed", "task": t.task, "minutes": 10])
                updateTodo(id, start: hhmm(Date().addingTimeInterval(600)))
            }
        case .equipSkin(let id): Skin.equip(id)
        case .planListTask(let id): if let t = listTasks.first(where: { $0.id == id }) { planFromList([t], day: .today) }
        case .planListTaskTomorrow(let id): if let t = listTasks.first(where: { $0.id == id }) { planFromList([t], day: .tomorrow) }
        case .startListTask(let id): if let t = listTasks.first(where: { $0.id == id }) { startFromList(t) }
        case .lockInEvent(let id):
            if let ev = events.first(where: { $0.id == id }) {
                startSession(task: ev.title, minutes: max(5, Int(ev.end.timeIntervalSince(Date()) / 60)))
            }
        case .skipEvent(let id):
            if let ev = events.first(where: { $0.id == id }) { appendLog(["type": "event_skipped", "what": ev.title]) }
        case .neverEvent(let id):
            if let ev = events.first(where: { $0.id == id }) { ignoreEvent(ev.title) }
        }
    }

    func ignoreEvent(_ title: String) {
        editConfig { raw in
            var list = raw["calendar_ignore"] as? [String] ?? []
            if !list.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) { list.append(title) }
            raw["calendar_ignore"] = list
        }
        reloadConfig()
    }
    func isIgnored(_ ev: CalEvent) -> Bool { (cfg.calendar_ignore ?? []).contains { $0.caseInsensitiveCompare(ev.title) == .orderedSame } }

    func showStats() { card = nil; statsShown = true }

    func showFlash(_ text: String, icon: String, tint: String = "green", seconds: Double = 4.5) {
        guard card == nil, !statsShown else { return }
        flashTask?.cancel()
        let f = Flash(text: text, icon: icon, tint: tint)
        flash = f
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.flash?.id == f.id { self?.flash = nil } } }
        flashTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Soft system sounds, quiet by default. One switch in Settings turns them all off.
    func play(_ name: String, volume: Float = 0.4) {
        guard cfg.sounds ?? true, let s = NSSound(named: name) else { return }
        s.volume = volume; s.play()
    }

    /// Stats for the views. Reading the log is cheap but views redraw every second, so it's kept for 20 seconds.
    private var statsCache: (at: Date, session: Double?, value: Stats)?
    func stats() -> Stats {
        if let c = statsCache, Date().timeIntervalSince(c.at) < 20, c.session == block?.started { return c.value }
        let s = Stats.load(goal: goal, weekGoal: cfg.stats_week_goal ?? 5, live: block)
        statsCache = (Date(), block?.started, s)
        return s
    }
    /// Today's minutes from finished sessions only (what "today counts" and earning free time go by).
    func finishedToday() -> Int { Stats.load(goal: goal, weekGoal: cfg.stats_week_goal ?? 5, live: nil).todayMinutes }

    func tapIsland() {
        guard let b = block else { return }
        if card != nil { card = nil; return }
        let stop = CardButton(label: locked && !isBreak ? "End early…" : "Stop", action: locked && !isBreak ? .confirmStop : .stop)
        show(Card(icon: isBreak ? "cup.and.saucer.fill" : "lock.fill", tint: isBreak ? "orange" : (drifting ? "red" : "green"),
                  title: isBreak ? "Break" : (b.task ?? "Locked in"), subtitle: "\(fmtTime(remaining)) left" + (isBreak ? "" : " · \((b.apps ?? []).prefix(3).joined(separator: ", "))"),
                  buttons: [stop, CardButton(label: "+5 min", action: .addFive), CardButton(label: "Keep going", action: .dismiss, primary: true)]), close: 6)
    }

    // MARK: loop

    private func tick() {
        now = Date()
        if let b = block, now.timeIntervalSince1970 >= b.ends { stopBlock(completed: b.kind == "focus"); return }
        if let c = card, let at = c.countdown, now >= at, let action = c.onTimeout { perform(action); return }
        checkIns()
    }

    /// Halfway and last-minute check-ins: a line drops out of the notch for a few seconds. Silent on purpose.
    private func checkIns() {
        guard cfg.check_ins ?? true, let b = block, b.kind == "focus", b.minutes >= 15, card == nil else { return }
        if progress >= 0.5, checkedIn.half != b.started {
            checkedIn.half = b.started
            let focused = b.tracked ? b.countedMinutes : max(0, Int((now.timeIntervalSince1970 - b.started - b.offSeconds) / 60))
            showFlash(drifting ? "Halfway. Come back to \(b.task ?? "it")" : "Halfway · \(focused) min focused so far",
                      icon: "circle.lefthalf.filled", tint: drifting ? "red" : "green")
        } else if remaining <= 60, checkedIn.last != b.started {
            checkedIn.last = b.started
            showFlash("Last minute. Finish the sentence you're on", icon: "hourglass", tint: "orange")
        }
    }

    private func check() {
        guard !checking, !gateShown else { if gateShown { blocked = nil }; return }
        if let b = block, b.kind == "focus", let p = preset {
            checking = true
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = Detect.context()
                let idle = Detect.idleSeconds()
                let realIdle = Detect.secondsSinceRealInput()
                let frame = Detect.windowFrame(of: ctx.app)
                Task { @MainActor in self.evaluate(ctx, idle: idle, realIdle: realIdle, frame: frame, preset: p); self.checking = false }
            }
        } else if block == nil, earning {
            checking = true
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = Detect.context(terminals: false)
                let frame = Detect.windowFrame(of: ctx.app)
                Task { @MainActor in self.evaluateFree(ctx, frame: frame); self.checking = false }
            }
        } else if blocked != nil { blocked = nil }
    }

    private func classify(_ c: FrontContext, _ p: Preset) -> (String, String?) {
        if anyIn(c.app, cfg.distractions.apps) != nil, anyIn(c.app, p.apps) == nil { return ("off", c.app) }
        if Detect.browsers[c.app] != nil {
            if anyIn(c.url + " " + c.title, p.sites) != nil { return ("on", nil) }   // the rule's own sites first
            if let hit = anyIn(c.url + " " + c.title, cfg.distractions.sites) { return ("off", hit) }
            return ("neutral", nil)
        }
        if let proj = c.project {
            if p.any_claude == true || anyIn(proj, p.projects) != nil { return ("on", nil) }
            return ("off", "Claude session in \((proj as NSString).lastPathComponent)")
        }
        if Detect.terminals.contains(c.app) {
            return p.terminal_ok ?? true ? ("on", nil) : ("off", "\(c.app) isn't part of this session")
        }
        if anyIn(c.app, p.apps) != nil || anyIn(c.app, cfg.always_ok_apps) != nil { return ("on", nil) }
        return ("neutral", nil)
    }

    private func evaluate(_ c: FrontContext, idle: Double, realIdle: Double, frame: NSRect?, preset p: Preset) {
        guard var b = block, b.kind == "focus" else { return }
        let dt = min(10, Date().timeIntervalSince(lastEval ?? Date().addingTimeInterval(-2)))
        lastEval = Date()
        // A site the rule explicitly allows wins over the cover (e.g. a NeetCode video on YouTube during LeetCode).
        let allowed = anyIn(c.url + " " + c.title, p.sites) != nil
        var (state, what) = classify(c, p)
        let appSnoozed = (snoozedSites["app:" + c.app] ?? .distantPast) >= Date()
        if Detect.browsers[c.app] != nil, !allowed, let site = anyIn(c.url, cfg.block_sites), (snoozedSites[site] ?? .distantPast) < Date() {
            cover(Blocked(site: site, app: c.app, frame: frame, kind: .site))
        } else if isDistractingApp(c.app, p), !appSnoozed {
            cover(Blocked(site: "", app: c.app, frame: frame, kind: .app))
        } else if strictViolation(c, p, state), !appSnoozed {
            cover(Blocked(site: "", app: c.app, frame: frame, kind: .strict))
            if state != "off" { state = "off"; what = "\(c.app) isn't part of this session" }
        } else if blocked != nil { blocked = nil }

        if state == "on", anyIn(c.app, cfg.always_ok_apps) == nil { lastOnTask = (c.app, c.url) }
        if p.offline_ok == true {
            if idle > (cfg.away_seconds ?? 45), state == "off" { state = "on" }
        } else if idle > (cfg.mac_away_seconds ?? 180) {
            state = "off"; what = "Away from your Mac for \(Int(idle / 60)) min"
        } else if idle > (cfg.away_seconds ?? 45), state == "off" { state = "neutral" }

        // What this moment earns: on task with real input lately counts; away on an offline-ok task counts; just
        // being here (or a mouse jiggler) doesn't.
        if state != "off" {
            if realIdle < Engine.activeWindow { b.activeSeconds = (b.activeSeconds ?? 0) + dt }
            else if p.offline_ok == true { b.offlineSeconds = (b.offlineSeconds ?? 0) + dt }
            else { b.idleSeconds = (b.idleSeconds ?? 0) + dt }
            block = b
        }
        guard state == "off", Date() >= snoozeUntil else {
            if state != "off" { driftSince = nil; lastNudge = nil; drifting = false }
            return
        }
        b.offSeconds += dt; block = b
        if driftSince == nil { driftSince = Date() }
        let away = what?.hasPrefix("Away") ?? false
        let offFor = Date().timeIntervalSince(driftSince!)
        drifting = offFor >= (away ? 0 : (cfg.drift_seconds ?? 30))
        let due = lastNudge == nil ? drifting : Date().timeIntervalSince(lastNudge!) >= (cfg.renudge_seconds ?? 120)
        if due, blocked == nil {
            if lastNudge == nil { appendLog(["type": "drift", "name": b.name, "what": what ?? ""]); play("Bottle", volume: 0.3) }
            lastNudge = Date()
            show(Card(icon: away ? "moon.zzz.fill" : "eye.fill", tint: "red", title: what ?? "Off task",
                      subtitle: "\(fmtTime(remaining)) left in \(b.task ?? "this session")",
                      buttons: [CardButton(label: "5 more min", action: .snoozeDrift), CardButton(label: "Back to it", action: .backToIt, primary: true)]), close: 8)
        }
    }

    /// Outside sessions, before today counts: distracting sites and apps get the cover.
    private func evaluateFree(_ c: FrontContext, frame: NSRect?) {
        guard block == nil, earning else { if blocked != nil { blocked = nil }; return }
        if Detect.browsers[c.app] != nil, let site = anyIn(c.url, cfg.block_sites), (snoozedSites[site] ?? .distantPast) < Date() {
            cover(Blocked(site: site, app: c.app, frame: frame, kind: .earn))
        } else if !neverCover(c.app), anyIn(c.app, cfg.distractions.apps) != nil, (snoozedSites["app:" + c.app] ?? .distantPast) < Date() {
            cover(Blocked(site: "", app: c.app, frame: frame, kind: .earn))
        } else if blocked != nil { blocked = nil }
    }

    /// Shows the cover, or moves it along with its window. A new cover is logged (the recap counts it) and plays a
    /// soft sound, at most every 30 seconds. In Locked mode a covered app gets hidden a moment later.
    private func cover(_ new: Blocked) {
        let fresh = blocked?.app != new.app || blocked?.site != new.site || blocked?.kind != new.kind
        if fresh {
            appendLog(["type": "blocked", "name": block?.name ?? "free time", "what": new.site.isEmpty ? new.app : new.site])
            coverShownAt = Date()
            if cfg.sounds ?? true, cfg.cover_sound ?? true, Date().timeIntervalSince(lastCoverSound) > 30, let s = NSSound(named: "Funk") {
                lastCoverSound = Date(); s.volume = 0.5; s.play()
            }
        }
        blocked = new
        if fresh, locked, new.site.isEmpty, new.kind != .site {
            let app = new.app
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.blocked?.app == app, self.blocked?.site.isEmpty == true else { return }
                self.hideBlockedApp()
            }
        }
    }

    /// Apps that can never be covered: lockin itself, macOS's own UI, and the always-fine list.
    private func neverCover(_ app: String) -> Bool {
        app.isEmpty || app == selfAppName || Detect.systemApps.contains(app) || anyIn(app, cfg.always_ok_apps) != nil
    }

    /// An app on the distracting list that this session doesn't explicitly allow.
    private func isDistractingApp(_ app: String, _ p: Preset) -> Bool {
        !neverCover(app) && anyIn(app, cfg.distractions.apps) != nil && anyIn(app, p.apps) == nil
    }

    /// Is the front app outside the session's apps? A browser you allowed is fine on any page that isn't a
    /// distraction; lockin's own windows, system UI and always-fine apps never count.
    private func strictViolation(_ c: FrontContext, _ p: Preset, _ state: String) -> Bool {
        guard state != "on", !neverCover(c.app) else { return false }
        if Detect.browsers[c.app] != nil, state == "neutral", anyIn(c.app, p.apps) != nil { return false }
        return true
    }

    // MARK: cover actions

    /// "Give me 5 min": after the wait, while passes last. Logged either way.
    func takePass() {
        guard let b = blocked, passesLeft > 0, snoozeWaitLeft == 0 else { return }
        let key = b.site.isEmpty ? "app:" + b.app : b.site
        snoozedSites[key] = Date().addingTimeInterval(300)
        appendLog(["type": "pass", "what": b.site.isEmpty ? b.app : b.site, "during": b.kind == .earn ? "free time" : (block?.name ?? "")])
        if b.kind == .earn { UserDefaults.standard.set(freePassesUsed + 1, forKey: freePassesKey) }
        else if var a = block { a.snoozes = (a.snoozes ?? 0) + 1; block = a; persist() }
        blocked = nil
    }
    /// A work app you need that wasn't part of the session: added for the rest of it (and remembered for the task).
    func addBlockedAppToSession() {
        guard canAddBlockedApp, snoozeWaitLeft == 0, let b = blocked, var a = block else { return }
        let apps = (a.apps ?? []) + [b.app]
        a.apps = apps; block = a; persist()
        appendLog(["type": "app_added", "app": b.app, "task": a.task ?? ""])
        if let id = a.todoId { updateTodo(id, apps: apps) }
        blocked = nil
    }
    /// Hides the covered app (it keeps running) and goes back to the last on-task app.
    func hideBlockedApp() {
        guard let app = blocked?.app else { return }
        NSWorkspace.shared.runningApplications.first { $0.localizedName == app }?.hide()
        backToWork()
    }
    /// ⌘Q on the cover: quits the covered app. Over a site the browser may be one you need, so the tab closes instead.
    func quitBlocked() {
        guard let b = blocked else { return }
        if !b.site.isEmpty, Detect.browsers[b.app] != nil { closeBlockedTab(); return }
        guard !neverCover(b.app), let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == b.app }) else { return }
        appendLog(["type": "quit_blocked", "app": b.app, "during": block?.name ?? "free time"])
        app.terminate()
        backToWork()
    }
    /// ⌘W on the cover: closes the covered tab, or hides the covered app.
    func closeOrHideBlocked() {
        guard let b = blocked else { return }
        if !b.site.isEmpty, Detect.browsers[b.app] != nil { closeBlockedTab() } else { hideBlockedApp() }
    }
    func closeBlockedTab() {
        guard let app = blocked?.app else { return }
        Detect.osa(Detect.browsers[app] == "safari" ? "tell application \"Safari\" to close current tab of front window"
                                                   : "tell application \"\(Detect.escape(app))\" to close active tab of front window")
        blocked = nil
    }
    func backToWork() {
        let app = blocked?.app ?? Detect.frontApp()
        blocked = nil
        if Detect.browsers[app] == "chromium", let sites = preset?.sites, !sites.isEmpty {
            let keys = sites.map { "\"\(Detect.escape($0))\"" }.joined(separator: ",")
            let src = """
            set keys to {\(keys)}
            tell application "\(Detect.escape(app))"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  repeat with k in keys
                    if (URL of t) contains (k as text) then
                      set active tab index of w to i
                      set index of w to 1
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "none"
            """
            if Detect.osa(src) == "ok" { return }
        }
        if let last = lastOnTask, last.app != app {
            NSWorkspace.shared.runningApplications.first { $0.localizedName == last.app }?.activate()
            return
        }
        if lastOnTask == nil, let p = preset, let target = NSWorkspace.shared.runningApplications.first(where: { r in
            r.activationPolicy == .regular && anyIn(r.localizedName ?? "", p.apps) != nil && r.localizedName != app }) {
            target.activate()   // nothing on task yet this session: jump to one of its apps
            return
        }
        if let last = lastOnTask, !last.url.isEmpty, Detect.browsers[app] != nil {
            Detect.osa("tell application \"\(Detect.escape(app))\" to set URL of active tab of front window to \"\(Detect.escape(last.url))\"")
            return
        }
        if Detect.browsers[app] == "chromium" { Detect.osa("tell application \"\(Detect.escape(app))\" to make new tab at end of tabs of front window") }
    }

    // MARK: to-dos

    /// Ticking off one of today's sessions moves the ones queued behind it up (`shift`).
    func setDone(_ id: String, _ done: Bool, shift: Bool = true) {
        let freed = done ? slot(of: id) : nil
        var d = TodoDoc.load()
        if let i = d.items.firstIndex(where: { $0.id == id }) { d.items[i].done = done }
        if let i = d.tomorrow?.firstIndex(where: { $0.id == id }) { d.tomorrow![i].done = done }
        d.save()
        if let tid = (d.items + (d.tomorrow ?? [])).first(where: { $0.id == id })?.task_id { setListDone(tid, done, plan: false) }
        reloadTodos()
        if shift, let freed, block?.todoId != id { shiftPlan(from: planAnchor, freed: freed) }
    }
    func addSpent(_ id: String, _ minutes: Int) {
        guard minutes > 0 else { return }
        var d = TodoDoc.load()
        if let i = d.items.firstIndex(where: { $0.id == id }) { d.items[i].spent = (d.items[i].spent ?? 0) + minutes }
        d.save(); reloadTodos()
    }

    /// Sends what you typed to the AI planner, which rewrites today's (or tomorrow's) plan; new tasks get their apps here.
    func sendToPlanner(_ text: String, day: PlanDay = .today) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !planning else { return }
        planning = true; planError = nil
        chat.append(ChatMsg(role: "user", text: t))
        _ = TodoDoc.load()     // roll the day over before the helper reads the file
        let cfg = self.cfg
        if cfg.ai?.provider == "apple" {      // Apple Intelligence runs in the app; the helper writes the prompt and applies the answer
            Task.detached(priority: .userInitiated) {
                var out = ""
                do {
                    let p = (try? JSONSerialization.jsonObject(with: Data(runCoach(["prompt", day.rawValue], input: t).utf8))) as? [String: Any]
                    guard let prompt = p?["prompt"] as? String else { throw AppleAI.failure(p?["error"] as? String ?? "couldn't build the prompt") }
                    let answer = try await AppleAI.plan(prompt: prompt)
                    let payload: [String: Any] = ["text": t, "result": (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) ?? [:]]
                    out = runCoach(["apply", day.rawValue], input: String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
                } catch {
                    out = String(data: (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data(), encoding: .utf8) ?? ""
                }
                let result = out
                await MainActor.run { self.finishPlanning(result, day: day, cfg: cfg) }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = runCoach(["todos", day.rawValue], input: t)
            Task { @MainActor in self.finishPlanning(out, day: day, cfg: cfg) }
        }
    }

    /// After the AI planner answers: new tasks get their apps, then the plan reloads (or the error shows).
    private func finishPlanning(_ out: String, day: PlanDay, cfg: Config) {
        DispatchQueue.global(qos: .userInitiated).async {
            let history = TaskMatch.history()
            var d = TodoDoc.load()
            var changed = false
            d.edit(day) { list in
                for i in list.indices where list[i].apps == nil {
                    let m = TaskMatch.apps(for: list[i].task, cfg: cfg, history: history)
                    list[i].apps = m.apps; list[i].block = m.rule ?? ""; changed = true
                }
            }
            if changed { d.save() }
            Task { @MainActor in
                self.planning = false
                let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
                if let err = obj?["error"] as? String { self.planError = err } else if obj == nil { self.planError = "no answer from the AI" }
                self.reloadTodos()
            }
        }
    }

    // MARK: morning plan, reminders, recap

    func planLines() -> [CardLine] {
        let text = runCoach(["plan"])
        var lines: [CardLine] = []
        for raw in text.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty && raw != "Today's plan" {
            if raw.hasPrefix("• ") {
                var t = String(raw.dropFirst(2)), trailing = "", deadline = false, time = "", calendar = false
                if let r = t.range(of: #"^\d{1,2}:\d{2} [AP]M · "#, options: .regularExpression) {
                    time = String(t[r].dropLast(3)); t.removeSubrange(r)
                }
                if let r = t.range(of: #"\s*\((\d+) min\)$"#, options: .regularExpression) {
                    trailing = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()")); t.removeSubrange(r)
                } else if let r = t.range(of: #"\s*\(until [^)]+\)$"#, options: .regularExpression) {   // calendar event
                    trailing = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()")); t.removeSubrange(r); calendar = true
                }
                if let r = t.range(of: " due ") {
                    deadline = true; trailing = String(t[r.upperBound...]).replacingOccurrences(of: "in ", with: "")
                    t = String(t[..<r.lowerBound]).replacingOccurrences(of: ":", with: "")
                }
                lines.append(CardLine(text: t, trailing: trailing, deadline: deadline, time: time, calendar: calendar))
            } else { lines.append(CardLine(text: raw, bullet: false)) }
        }
        return lines
    }

    func showPlan(morning: Bool = false) {
        let h = Calendar.current.component(.hour, from: Date())
        let title = morning ? "Good morning" : (h < 12 ? "Today" : h < 18 ? "Rest of today" : "Tonight")
        let n = nextTodo
        show(Card(icon: morning || h < 18 ? "sun.max.fill" : "moon.fill", tint: "orange", title: title, lines: planLines(),
                  buttons: [CardButton(label: n == nil ? "Later" : "Open plan", action: n == nil ? .dismiss : .openPlanner),
                            n.map { CardButton(label: "Lock in: \($0.task.prefix(24))\($0.task.count > 24 ? "…" : "")", action: .startNext, primary: true) }
                              ?? CardButton(label: "Plan", action: .openPlanner, primary: true)], autoClose: 30))
    }

    func showRecap() {
        let text = runCoach(["recap"]).replacingOccurrences(of: "Recap: ", with: "")
        var lines = text.split(separator: "\n").map { CardLine(text: String($0), bullet: false) }
        let st = stats()
        lines.append(CardLine(text: "This week: \(fmtMinutes(st.weekMinutes)) over \(st.weekDaysCounted) of \(st.weekGoal) days · streak \(st.streak)", bullet: false))
        let planned = !tomorrow.isEmpty
        show(Card(icon: "chart.bar.fill", tint: "blue", title: "Today", subtitle: "\(fmtMinutes(st.todayMinutes)) focused",
                  lines: lines, buttons: [CardButton(label: "Stats", action: .openStats),
                                          planned ? CardButton(label: "Nice", action: .dismiss, primary: true)
                                                  : CardButton(label: "Plan tomorrow", action: .planTomorrow, primary: true)]))
    }

    private func minute() {
        if today() != lastDay {          // 4am: a fresh day; leftovers to the backlog, tomorrow's plan becomes today's
            lastDay = today(); reloadTodos(); askedEvents = []; promptedTodos = []
        }
        minuteCount += 1
        if minuteCount % 10 == 0 { refreshEvents() }
        if block?.kind == "focus" { persist() }
        todayMinutes = finishedToday()
        catchUp(); morningCheck(); duePlanned(); dueEvents(); dueNudge(); idleNudge()
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if f.string(from: Date()) == (cfg.recap_at ?? "21:00") { showRecap() }
        if let at = cfg.streak_reminder, !at.isEmpty, f.string(from: Date()) >= at { streakReminder() }
    }

    /// A planned start went by without its session (away, asleep, auto-start off, another session ran long): the rest of
    /// today slides to fit. Repeats and calendar sessions keep their time.
    private func catchUp() {
        let now = Date()
        let missed = todos.contains { t in
            guard !t.isDone, t.source == nil, t.id != block?.todoId, let s = parseHHMM(t.start ?? "") else { return false }
            return now.timeIntervalSince(s) >= 120
        }
        guard missed else { return }
        let n = shiftPlan(from: planAnchor)
        if n > 0, let next = todos.first(where: { t in !t.isDone && t.id != block?.todoId && (parseHHMM(t.start ?? "").map { $0 >= now } ?? false) }) {
            showFlash("Plan moved · \(next.task) at \(clockLabel(next.start))", icon: "clock.arrow.circlepath", tint: "blue")
        }
    }

    /// A planned session's time came: a countdown in the notch, then it starts ("In 10 min" moves it).
    private func duePlanned() {
        guard cfg.auto_start ?? true, block == nil, card == nil, !gateShown, !SetupWindow.needed else { return }
        let t0 = Date()
        guard let t = todos.first(where: { t in
            guard !t.isDone, let s = parseHHMM(t.start ?? ""), !promptedTodos.contains(t.id + (t.start ?? "")) else { return false }
            let d = t0.timeIntervalSince(s)
            return d >= 0 && d < 120
        }) else { return }
        promptedTodos.insert(t.id + (t.start ?? ""))
        play("Purr", volume: 0.35)
        show(Card(icon: "lock.fill", tint: "green", title: t.task, subtitle: "Starting now · \(t.left) min · \((t.apps ?? []).prefix(3).joined(separator: ", "))",
                  buttons: [CardButton(label: "In 10 min", action: .snoozeTodo(t.id)), CardButton(label: "Start", action: .startTodo(t.id), primary: true)],
                  countdown: t0.addingTimeInterval(15), onTimeout: .startTodo(t.id)))
    }

    /// A calendar event is starting: ask (never jump in). "Never for this" is remembered by title.
    private func dueEvents() {
        guard (cfg.calendar_mode ?? "ask") != "off", card == nil, !gateShown else { return }
        let t0 = Date()
        guard let ev = events.first(where: { e in
            !e.allDay && !askedEvents.contains(e.id) && !isIgnored(e) && t0 >= e.start && t0.timeIntervalSince(e.start) < 180 && e.end > t0
        }) else { return }
        askedEvents.insert(ev.id)
        if todos.contains(where: { !$0.isDone && $0.start == ev.startHHMM }) { return }   // a planned session covers it
        if block != nil { showFlash("\(ev.title) is starting (calendar)", icon: "calendar", tint: "blue"); return }
        play("Purr", volume: 0.3)
        let left = max(5, Int(ev.end.timeIntervalSince(t0) / 60))
        show(Card(icon: "calendar", tint: "blue", title: ev.title,
                  subtitle: "On your calendar until \(ev.end.formatted(date: .omitted, time: .shortened)). Lock in for it?",
                  buttons: [CardButton(label: "Never for this", action: .neverEvent(ev.id)), CardButton(label: "Skip", action: .skipEvent(ev.id)),
                            CardButton(label: "Lock in · \(left) min", action: .lockInEvent(ev.id), primary: true)]), close: 90)
    }

    /// Once an evening, if today hasn't counted yet: one card, then silence until tomorrow.
    private func streakReminder() {
        let key = "streakReminderShown"
        guard UserDefaults.standard.string(forKey: key) != today(), block == nil, card == nil, !gateShown, Detect.idleSeconds() < 120 else { return }
        if anyIn(Detect.frontApp(), ["zoom.us", "Microsoft Teams", "FaceTime", "Webex"]) != nil { return }
        let st = stats()
        guard st.todayMinutes < st.goal, st.streak > 0 || st.weekDaysCounted < st.weekGoal else { return }
        UserDefaults.standard.set(today(), forKey: key)
        let need = st.goal - st.todayMinutes
        let title = st.streak > 0 ? "Keep your \(st.streak)-day streak" : "Put today on the board"
        let sub = st.todayMinutes > 0 ? "\(need) more minutes makes today count." : "One \(max(need, 25))-minute session makes today count. \(st.weekDaysCounted)/\(st.weekGoal) days this week."
        play("Purr", volume: 0.3)
        show(Card(icon: "flame.fill", tint: "orange", title: title, subtitle: sub,
                  buttons: [CardButton(label: "Not tonight", action: .dismiss), CardButton(label: "Lock in \(max(need, 25)) min", action: .startGoal, primary: true)]), close: 30)
    }

    /// The first time you're at the Mac each day (after the morning hour): the full-screen plan, or the plan card if
    /// the morning screen is off. Not while a session runs; starting one counts as starting the day.
    func morningCheck() {
        var s = AppState.load()
        guard s.plan_shown != today(), Calendar.current.component(.hour, from: Date()) >= (cfg.morning_hour ?? 5),
              Detect.idleSeconds() < 90, !SetupWindow.needed, block == nil, !gateShown else { return }
        reloadTodos()
        if cfg.morning_gate ?? true { Gate.shared.show() }
        else { s.plan_shown = today(); s.save(); showPlan(morning: true) }
    }

    private func idleNudge() {
        guard block == nil, card == nil, !gateShown else { return }
        let h = Calendar.current.component(.hour, from: Date()), hours = cfg.active_hours ?? [8, 23]
        guard h >= hours[0], h < hours[1], Detect.idleSeconds() < 60 else { return }
        let gap = (cfg.idle_nudge_minutes ?? 40) * 60
        guard Date().timeIntervalSince(lastIdleNudge) >= gap, Date().timeIntervalSince(lastBlockEnd) >= gap else { return }
        if anyIn(Detect.frontApp(), ["zoom.us", "Microsoft Teams", "FaceTime", "Webex"]) != nil { return }
        lastIdleNudge = Date()
        if let n = nextTodo {
            let left = todos.filter { !$0.isDone }.count
            show(Card(icon: "arrow.right.circle.fill", tint: "green", title: n.task,
                      subtitle: "Up next · \(n.left) min · \(left) left today. Hard to start? Do 10 minutes.",
                      buttons: [CardButton(label: "Later", action: .dismiss), CardButton(label: "Just 10 min", action: .startTen),
                                CardButton(label: "Lock in", action: .startNext, primary: true)]), close: 25)
        } else {
            show(Card(icon: "list.bullet.rectangle.fill", tint: "green", title: "What are you locking in on?",
                      subtitle: "Nothing's planned. Type it in one line and lockin times it for you.",
                      buttons: [CardButton(label: "Later", action: .dismiss), CardButton(label: "Plan", action: .openPlanner, primary: true)]), close: 25)
        }
    }
}
